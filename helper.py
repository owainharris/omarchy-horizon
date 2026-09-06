#!/usr/bin/python3
"""Security boundary for Horizon state, images, and file selection."""

from __future__ import annotations

import hashlib
import json
import os
import pwd
import secrets
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

MAX_SOURCE_BYTES = 256 * 1024 * 1024
MAX_STATE_BYTES = 64 * 1024
MAX_PATH_BYTES = 4096
MAX_MONITORS = 32
MAX_GEOMETRY_BYTES = 16 * 1024
MAX_CANVAS_PIXELS = 40_000_000
MAX_DIMENSION = 32_768
MAX_OUTPUT_FILE_BYTES = 256 * 1024 * 1024
MAX_TOOL_FILE_BYTES = 2 * 1024 * 1024 * 1024
SYSTEM_UID = os.stat("/").st_uid

EMPTY_STATE = {
    "version": 1,
    "source": "",
    "createdAt": "",
    "scaleMode": "fill",
    "bounds": {"x": 0, "y": 0, "width": 0, "height": 0},
    "monitors": [],
}


class HelperError(Exception):
    pass


def default_state_root() -> Path:
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    return home / ".local" / "state" / "omarchy" / "span-wallpaper"


def bounded_path(value: str) -> str:
    if not value or "\x00" in value or any(ord(char) < 32 for char in value):
        raise HelperError("the selected path is invalid")
    if len(os.fsencode(value)) > MAX_PATH_BYTES:
        raise HelperError("the selected path is too long")
    return value


def safe_name(value: Any) -> str:
    name = str(value)
    if not name or len(name.encode("utf-8")) > 128 or any(ord(char) < 32 for char in name):
        raise HelperError("monitor name is invalid")
    return name


def open_directory_path(path: Path) -> int:
    if not path.is_absolute():
        raise HelperError("state path must be absolute")
    current = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    built = Path("/")
    try:
        for component in path.parts[1:]:
            built /= component
            try:
                child = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=current,
                )
            except FileNotFoundError:
                os.mkdir(component, 0o700, dir_fd=current)
                child = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=current,
                )
            info = os.fstat(child)
            sticky_root_tmp = built == Path("/tmp") and info.st_uid == SYSTEM_UID and info.st_mode & stat.S_ISVTX
            if info.st_uid not in (SYSTEM_UID, os.getuid()) or (info.st_mode & 0o022 and not sticky_root_tmp):
                os.close(child)
                raise HelperError(f"unsafe state directory component: {built}")
            os.close(current)
            current = child
        info = os.fstat(current)
        if info.st_uid != os.getuid():
            raise HelperError("state directory is not owned by the current user")
        os.fchmod(current, 0o700)
        return current
    except Exception:
        os.close(current)
        raise


class StateStore:
    def __init__(self, root: Path | None = None) -> None:
        self.root = (root or default_state_root()).absolute()
        self.fd = open_directory_path(self.root)

    def close(self) -> None:
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1

    def __enter__(self) -> "StateStore":
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()

    def ensure_dir(self, name: str) -> int:
        if "/" in name or name in ("", ".", ".."):
            raise HelperError("invalid state directory name")
        try:
            os.mkdir(name, 0o700, dir_fd=self.fd)
        except FileExistsError:
            pass
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=self.fd,
        )
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid():
            os.close(descriptor)
            raise HelperError("state subdirectory has unsafe ownership")
        os.fchmod(descriptor, 0o700)
        return descriptor

    def create_dir(self, prefix: str) -> tuple[str, int]:
        for _attempt in range(32):
            name = f"{prefix}{secrets.token_hex(8)}"
            try:
                os.mkdir(name, 0o700, dir_fd=self.fd)
            except FileExistsError:
                continue
            return name, self.ensure_dir(name)
        raise HelperError("could not allocate private state directory")

    def open_relative_file(self, relative: str, maximum: int) -> tuple[int, os.stat_result]:
        parts = Path(relative).parts
        if Path(relative).is_absolute() or not parts or any(part in ("", ".", "..") for part in parts):
            raise HelperError("state file path is invalid")
        directory = os.dup(self.fd)
        try:
            for component in parts[:-1]:
                child = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=directory,
                )
                info = os.fstat(child)
                if info.st_uid != os.getuid() or info.st_mode & 0o022:
                    os.close(child)
                    raise HelperError("state path has unsafe ownership or permissions")
                os.close(directory)
                directory = child
            descriptor = os.open(
                parts[-1],
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=directory,
            )
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                os.close(descriptor)
                raise HelperError("state entry is not a regular file")
            if info.st_uid != os.getuid() or info.st_mode & 0o022:
                os.close(descriptor)
                raise HelperError("state entry has unsafe ownership or permissions")
            if info.st_size < 0 or info.st_size > maximum:
                os.close(descriptor)
                raise HelperError("state entry exceeds its size limit")
            return descriptor, info
        finally:
            os.close(directory)

    def relative_for(self, path: str) -> str:
        candidate = Path(bounded_path(path))
        try:
            relative = candidate.relative_to(self.root)
        except ValueError as error:
            raise HelperError("state references a file outside its private directory") from error
        return str(relative)

    def read_state(self) -> dict[str, Any]:
        try:
            descriptor, info = self.open_relative_file("state.json", MAX_STATE_BYTES)
        except FileNotFoundError:
            return dict(EMPTY_STATE)
        try:
            data = read_exact(descriptor, info.st_size, MAX_STATE_BYTES)
        finally:
            os.close(descriptor)
        try:
            value = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise HelperError("saved wallpaper state is invalid") from error
        return validate_state(self, value)

    def state_exists(self) -> bool:
        try:
            info = os.stat("state.json", dir_fd=self.fd, follow_symlinks=False)
        except FileNotFoundError:
            return False
        if not stat.S_ISREG(info.st_mode):
            raise HelperError("wallpaper state is not a regular file")
        return True

    def publish_state(self, value: dict[str, Any]) -> None:
        validated = validate_state(self, value)
        payload = (json.dumps(validated, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        if len(payload) > MAX_STATE_BYTES:
            raise HelperError("wallpaper state exceeds its size limit")
        temporary = f".state-{secrets.token_hex(8)}"
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
            dir_fd=self.fd,
        )
        try:
            write_all(descriptor, payload)
            os.fsync(descriptor)
        except Exception:
            try:
                os.unlink(temporary, dir_fd=self.fd)
            except FileNotFoundError:
                pass
            raise
        finally:
            os.close(descriptor)
        os.rename(temporary, "state.json", src_dir_fd=self.fd, dst_dir_fd=self.fd)
        os.fsync(self.fd)


def read_exact(descriptor: int, expected: int, maximum: int) -> bytes:
    if expected > maximum:
        raise HelperError("file exceeds its size limit")
    chunks: list[bytes] = []
    remaining = expected
    while remaining:
        chunk = os.read(descriptor, min(1024 * 1024, remaining))
        if not chunk:
            raise HelperError("file changed while it was being read")
        chunks.append(chunk)
        remaining -= len(chunk)
    if os.read(descriptor, 1):
        raise HelperError("file changed while it was being read")
    return b"".join(chunks)


def write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        view = view[written:]


def checked_int(value: Any, label: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool):
        raise HelperError(f"{label} is invalid")
    try:
        number = int(value)
    except (TypeError, ValueError) as error:
        raise HelperError(f"{label} is invalid") from error
    if number < minimum or number > maximum:
        raise HelperError(f"{label} is outside the supported range")
    return number


def normalize_monitors(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not 1 <= len(value) <= MAX_MONITORS:
        raise HelperError("select between 1 and 32 monitors")
    result: list[dict[str, Any]] = []
    names: set[str] = set()
    for item in value:
        if not isinstance(item, dict):
            raise HelperError("monitor geometry is invalid")
        name = safe_name(item.get("name", ""))
        if name in names:
            raise HelperError("monitor names must be unique")
        names.add(name)
        result.append(
            {
                "name": name,
                "x": checked_int(item.get("x"), "monitor x", -1_000_000, 1_000_000),
                "y": checked_int(item.get("y"), "monitor y", -1_000_000, 1_000_000),
                "width": checked_int(item.get("width"), "monitor width", 1, MAX_DIMENSION),
                "height": checked_int(item.get("height"), "monitor height", 1, MAX_DIMENSION),
            }
        )
    result.sort(key=lambda item: (item["x"], item["y"], item["name"]))
    left = min(item["x"] for item in result)
    top = min(item["y"] for item in result)
    right = max(item["x"] + item["width"] for item in result)
    bottom = max(item["y"] + item["height"] for item in result)
    width, height = right - left, bottom - top
    if width > MAX_DIMENSION or height > MAX_DIMENSION or width * height > MAX_CANVAS_PIXELS:
        raise HelperError("selected monitor canvas is too large")
    return result


def validate_state(store: StateStore, value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("version") != 1:
        raise HelperError("saved wallpaper state has an unsupported schema")
    source = value.get("source", "")
    monitors = value.get("monitors", [])
    if not isinstance(source, str) or not isinstance(monitors, list) or len(monitors) > MAX_MONITORS:
        raise HelperError("saved wallpaper state is invalid")
    if not source and not monitors:
        return dict(EMPTY_STATE)
    normalized = normalize_monitors(monitors)
    source_relative = store.relative_for(source)
    source_fd, _source_info = store.open_relative_file(source_relative, MAX_SOURCE_BYTES)
    os.close(source_fd)
    files_by_name: dict[str, str] = {}
    for original in monitors:
        if not isinstance(original, dict) or not isinstance(original.get("file"), str):
            raise HelperError("saved monitor crop is invalid")
        name = safe_name(original.get("name", ""))
        if name in files_by_name:
            raise HelperError("saved monitor names must be unique")
        files_by_name[name] = original["file"]
    output: list[dict[str, Any]] = []
    for normalized_item in normalized:
        crop_relative = store.relative_for(files_by_name[normalized_item["name"]])
        crop_fd, _crop_info = store.open_relative_file(crop_relative, MAX_OUTPUT_FILE_BYTES)
        os.close(crop_fd)
        output.append({**normalized_item, "file": str(store.root / crop_relative)})
    left = min(item["x"] for item in normalized)
    top = min(item["y"] for item in normalized)
    right = max(item["x"] + item["width"] for item in normalized)
    bottom = max(item["y"] + item["height"] for item in normalized)
    mode = value.get("scaleMode", "fill")
    if mode not in ("fill", "fit", "stretch"):
        raise HelperError("saved scale mode is invalid")
    created = value.get("createdAt", "")
    if not isinstance(created, str) or len(created) > 64 or any(ord(char) < 32 for char in created):
        raise HelperError("saved creation time is invalid")
    return {
        "version": 1,
        "source": str(store.root / source_relative),
        "createdAt": created,
        "scaleMode": mode,
        "bounds": {"x": left, "y": top, "width": right - left, "height": bottom - top},
        "monitors": output,
    }


def open_source(path: str) -> tuple[int, os.stat_result]:
    bounded_path(path)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise HelperError("selected image could not be opened safely") from error
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode):
        os.close(descriptor)
        raise HelperError("selected image must be a regular file")
    if info.st_uid not in (SYSTEM_UID, os.getuid()) or info.st_mode & 0o022:
        os.close(descriptor)
        raise HelperError("selected image has unsafe ownership or permissions")
    if not 0 < info.st_size <= MAX_SOURCE_BYTES:
        os.close(descriptor)
        raise HelperError("selected image must be between 1 byte and 256 MiB")
    return descriptor, info


def image_format(descriptor: int) -> str:
    header = os.pread(descriptor, 32, 0)
    if header.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if header.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if header.startswith((b"GIF87a", b"GIF89a")):
        return "gif"
    if header.startswith(b"BM"):
        return "bmp"
    if len(header) >= 12 and header[:4] == b"RIFF" and header[8:12] == b"WEBP":
        return "webp"
    raise HelperError("selected file is not a supported image")


def image_fd_spec(descriptor: int) -> str:
    # Wallpapers are static: do not decode an entire animation or write a
    # multi-image stream into a file intended to contain a single PNG.
    return f"{image_format(descriptor)}:/proc/self/fd/{descriptor}[0]"


def trusted_tool(path: str) -> str:
    resolved = os.path.realpath(path)
    descriptor = os.open(resolved, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != SYSTEM_UID or info.st_mode & 0o022:
            raise HelperError(f"required tool is not trusted: {path}")
    finally:
        os.close(descriptor)
    return resolved


def create_private_dir(parent_fd: int, prefix: str) -> tuple[str, int]:
    for _attempt in range(32):
        name = f"{prefix}{secrets.token_hex(8)}"
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            continue
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            os.close(descriptor)
            raise HelperError("private work directory has unsafe metadata")
        return name, descriptor
    raise HelperError("could not allocate private work directory")


def open_temporary_parent() -> int:
    descriptor = os.open("/tmp", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    info = os.fstat(descriptor)
    if info.st_uid != SYSTEM_UID or not info.st_mode & stat.S_ISVTX:
        os.close(descriptor)
        raise HelperError("temporary directory has unsafe metadata")
    return descriptor


def run_tool(
    arguments: list[str],
    timeout: float,
    environment: dict[str, str],
    pass_fds: tuple[int, ...] = (),
    operation: str = "image processing",
) -> None:
    limiter = trusted_tool("/usr/bin/prlimit")
    command = [limiter, f"--fsize={MAX_TOOL_FILE_BYTES}:{MAX_TOOL_FILE_BYTES}", "--", *arguments]
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=environment,
            close_fds=True,
            pass_fds=pass_fds,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise HelperError(f"{operation} timed out") from error
    if result.returncode != 0:
        raise HelperError(f"ImageMagick failed during {operation}")


def import_source(store: StateStore, source_path: str) -> str:
    source_fd, before = open_source(source_path)
    sources_fd = store.ensure_dir("sources")
    temporary = f".source-{secrets.token_hex(8)}"
    destination_fd = -1
    try:
        destination_fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
            dir_fd=sources_fd,
        )
        digest = hashlib.sha256()
        remaining = before.st_size
        while remaining:
            chunk = os.read(source_fd, min(1024 * 1024, remaining))
            if not chunk:
                raise HelperError("selected image changed while it was being copied")
            digest.update(chunk)
            write_all(destination_fd, chunk)
            remaining -= len(chunk)
        if os.read(source_fd, 1):
            raise HelperError("selected image changed while it was being copied")
        after = os.fstat(source_fd)
        stable_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
            raise HelperError("selected image changed while it was being copied")
        os.fsync(destination_fd)
        os.close(destination_fd)
        destination_fd = -1
        final_name = f"{digest.hexdigest()}.img"
        try:
            existing = os.open(final_name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=sources_fd)
        except FileNotFoundError:
            os.rename(temporary, final_name, src_dir_fd=sources_fd, dst_dir_fd=sources_fd)
        else:
            existing_info = os.fstat(existing)
            os.close(existing)
            if (
                not stat.S_ISREG(existing_info.st_mode)
                or existing_info.st_uid != os.getuid()
                or existing_info.st_mode & 0o022
                or existing_info.st_size != before.st_size
            ):
                raise HelperError("retained image has unsafe metadata")
            os.unlink(temporary, dir_fd=sources_fd)
        os.fsync(sources_fd)
        retained = str(store.root / "sources" / final_name)
        retained_fd, _retained_info = store.open_relative_file(f"sources/{final_name}", MAX_SOURCE_BYTES)
        magick = trusted_tool("/usr/bin/magick")
        environment = {"HOME": pwd.getpwuid(os.getuid()).pw_dir, "LANG": "C.UTF-8", "PATH": "/usr/bin"}
        try:
            run_tool(
                [magick, "identify", "-limit", "memory", "256MiB", "-limit", "map", "512MiB", "-ping", image_fd_spec(retained_fd)],
                15,
                environment,
                (retained_fd,),
                "image validation",
            )
        finally:
            os.close(retained_fd)
        return retained
    finally:
        os.close(source_fd)
        if destination_fd >= 0:
            os.close(destination_fd)
        try:
            os.unlink(temporary, dir_fd=sources_fd)
        except FileNotFoundError:
            pass
        os.close(sources_fd)


def remove_private_dir(parent_fd: int, name: str, descriptor: int) -> None:
    # A child may traverse the inherited directory through /proc/self/fd, which
    # can leave this open file description's directory offset at EOF.
    os.lseek(descriptor, 0, os.SEEK_SET)
    for entry in os.listdir(descriptor):
        try:
            os.unlink(entry, dir_fd=descriptor)
        except IsADirectoryError as error:
            raise HelperError("unexpected directory in private work area") from error
    os.close(descriptor)
    os.rmdir(name, dir_fd=parent_fd)


def crop(store: StateStore, source: str, geometry_raw: str, mode: str) -> None:
    if len(geometry_raw.encode("utf-8")) > MAX_GEOMETRY_BYTES:
        raise HelperError("monitor geometry exceeds its size limit")
    try:
        monitors = normalize_monitors(json.loads(geometry_raw))
    except json.JSONDecodeError as error:
        raise HelperError("monitor geometry is invalid") from error
    if mode not in ("fill", "fit", "stretch"):
        raise HelperError("scale mode is invalid")

    source_relative = store.relative_for(source)
    source_fd, _source_info = store.open_relative_file(source_relative, MAX_SOURCE_BYTES)
    left = min(item["x"] for item in monitors)
    top = min(item["y"] for item in monitors)
    right = max(item["x"] + item["width"] for item in monitors)
    bottom = max(item["y"] + item["height"] for item in monitors)
    canvas_width, canvas_height = right - left, bottom - top

    temporary_parent_fd = open_temporary_parent()
    work_name, work_fd = create_private_dir(temporary_parent_fd, "span-wallpaper-")
    output_name, output_fd = store.create_dir("set-")
    virtual_fd = os.open(
        "virtual.png",
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
        dir_fd=work_fd,
    )
    magick = trusted_tool("/usr/bin/magick")
    output_path = store.root / output_name
    environment = {
        "HOME": pwd.getpwuid(os.getuid()).pw_dir,
        "LANG": "C.UTF-8",
        "MAGICK_TEMPORARY_PATH": f"/proc/self/fd/{work_fd}",
        "PATH": "/usr/bin",
    }
    limits = ["-limit", "thread", "4", "-limit", "memory", "768MiB", "-limit", "map", "1GiB", "-limit", "disk", "2GiB"]
    decoder = ["-define", f"jpeg:size={canvas_width}x{canvas_height}"] if image_format(source_fd) == "jpeg" else []
    if mode == "fill":
        scale = ["-resize", f"{canvas_width}x{canvas_height}^", "-gravity", "center", "-extent", f"{canvas_width}x{canvas_height}"]
    elif mode == "fit":
        scale = ["-resize", f"{canvas_width}x{canvas_height}", "-gravity", "center", "-background", "black", "-extent", f"{canvas_width}x{canvas_height}"]
    else:
        scale = ["-resize", f"{canvas_width}x{canvas_height}!"]

    completed = False
    try:
        run_tool(
            [magick, *limits, *decoder, image_fd_spec(source_fd), "-auto-orient", *scale, "+repage", "-define", "png:compression-level=1", f"png:/proc/self/fd/{virtual_fd}"],
            30,
            environment,
            (source_fd, work_fd, virtual_fd),
            "canvas preparation",
        )
        virtual_info = os.fstat(virtual_fd)
        if not 0 < virtual_info.st_size <= MAX_OUTPUT_FILE_BYTES:
            raise HelperError("prepared canvas exceeds its size limit")
        os.close(virtual_fd)
        virtual_fd = -1
        virtual_fd = os.open(
            "virtual.png",
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=work_fd,
        )
        entries: list[dict[str, Any]] = []
        for index, monitor in enumerate(monitors):
            file_name = f"crop-{index:02d}-{hashlib.sha256(monitor['name'].encode()).hexdigest()[:12]}.png"
            destination = output_path / file_name
            crop_geometry = f"{monitor['width']}x{monitor['height']}+{monitor['x'] - left}+{monitor['y'] - top}"
            generated_fd = os.open(
                file_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
                dir_fd=output_fd,
            )
            try:
                run_tool(
                    [magick, *limits, f"png:/proc/self/fd/{virtual_fd}", "-gravity", "NorthWest", "-crop", crop_geometry, "+repage", "-define", "png:compression-level=1", f"png:/proc/self/fd/{generated_fd}"],
                    30,
                    environment,
                    (work_fd, virtual_fd, generated_fd),
                    f"crop {index + 1}",
                )
                generated_info = os.fstat(generated_fd)
            finally:
                os.close(generated_fd)
            if generated_info.st_size > MAX_OUTPUT_FILE_BYTES:
                raise HelperError("monitor crop exceeds its size limit")
            if generated_info.st_size == 0:
                raise HelperError("ImageMagick produced an empty monitor crop")
            entries.append({**monitor, "file": str(destination)})
        state = {
            "version": 1,
            "source": source,
            "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "scaleMode": mode,
            "bounds": {"x": left, "y": top, "width": canvas_width, "height": canvas_height},
            "monitors": entries,
        }
        store.publish_state(state)
        completed = True
    finally:
        os.close(source_fd)
        if virtual_fd >= 0:
            os.close(virtual_fd)
        remove_private_dir(temporary_parent_fd, work_name, work_fd)
        os.close(temporary_parent_fd)
        if completed:
            os.close(output_fd)
        else:
            remove_private_dir(store.fd, output_name, output_fd)


def picker_initial(selected: str, theme_only: bool) -> str:
    if selected:
        selected_path = Path(bounded_path(selected))
        if selected_path.is_file():
            return str(selected_path.parent)
    if theme_only:
        theme = default_state_root().parent / "current" / "theme" / "backgrounds"
        if theme.is_dir():
            return str(theme)
    return pwd.getpwuid(os.getuid()).pw_dir


def pick_file(selected: str, theme_only: bool) -> str:
    try:
        import gi

        gi.require_version("Gtk", "4.0")
        from gi.repository import Gio, GLib, Gtk
    except (ImportError, ValueError) as error:
        raise HelperError("GTK 4 Python bindings are unavailable") from error

    chosen = ""
    failure = ""
    loop = GLib.MainLoop()
    dialog = Gtk.FileDialog.new()
    dialog.set_title("Choose an image to span")
    images = Gtk.FileFilter()
    images.set_name("Images")
    for mime_type in ("image/jpeg", "image/png", "image/webp", "image/gif", "image/bmp"):
        images.add_mime_type(mime_type)
    filters = Gio.ListStore.new(Gtk.FileFilter)
    filters.append(images)
    dialog.set_filters(filters)
    dialog.set_default_filter(images)
    dialog.set_initial_folder(Gio.File.new_for_path(picker_initial(selected, theme_only)))

    def finish(chooser: Any, result: Any) -> None:
        nonlocal chosen, failure
        try:
            item = chooser.open_finish(result)
            if item is not None and item.get_path():
                chosen = bounded_path(item.get_path())
        except GLib.Error as error:
            cancelled = error.matches(Gtk.DialogError.quark(), int(Gtk.DialogError.CANCELLED)) or error.matches(
                Gtk.DialogError.quark(), int(Gtk.DialogError.DISMISSED)
            )
            if not cancelled:
                failure = "the image chooser failed"
        finally:
            loop.quit()

    dialog.open(None, None, finish)
    loop.run()
    if failure:
        raise HelperError(failure)
    return chosen


def emit_json(value: Any) -> None:
    payload = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    if len(payload.encode("utf-8")) > MAX_STATE_BYTES:
        raise HelperError("helper response exceeds its size limit")
    print(payload, flush=True)


def main(arguments: list[str]) -> int:
    if not arguments:
        raise HelperError("missing helper action")
    action = arguments[0]
    with StateStore() as store:
        if action == "init" and len(arguments) == 1:
            if store.state_exists():
                store.read_state()
            else:
                store.publish_state(dict(EMPTY_STATE))
        elif action == "read" and len(arguments) == 1:
            emit_json(store.read_state())
        elif action == "clear" and len(arguments) == 1:
            store.publish_state(dict(EMPTY_STATE))
        elif action == "import" and len(arguments) == 2:
            emit_json({"path": import_source(store, arguments[1])})
        elif action == "crop" and len(arguments) == 4:
            crop(store, arguments[1], arguments[2], arguments[3])
        elif action == "pick" and len(arguments) == 3:
            emit_json({"path": pick_file(arguments[1], arguments[2] == "theme")})
        else:
            raise HelperError("invalid helper action")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except HelperError as error:
        print(str(error)[:512], file=sys.stderr, flush=True)
        raise SystemExit(1)
    except OSError:
        print("a secure file operation failed", file=sys.stderr, flush=True)
        raise SystemExit(1)
