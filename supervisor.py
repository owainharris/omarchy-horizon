#!/usr/bin/python3
"""Run one helper with bounded output and process-tree supervision."""

from __future__ import annotations

import argparse
import ctypes
import os
import selectors
import signal
import stat
import subprocess
import sys
import time

MAX_OUTPUT = 65_536
MAX_TIMEOUT_MS = 180_000
TERM_GRACE_SECONDS = 1.5
PR_SET_PDEATHSIG = 1
PR_SET_CHILD_SUBREAPER = 36
SYSTEM_UID = os.stat("/").st_uid


def fail(message: str, code: int = 64) -> int:
    print(message[:512], file=sys.stderr, flush=True)
    return code


def set_parent_death_signal(parent: int) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_PDEATHSIG) failed")
    if os.getppid() != parent:
        raise SystemExit(143)


def trusted_executable(path: str) -> str:
    if not os.path.isabs(path):
        raise ValueError("helper executable must use an absolute path")
    resolved = os.path.realpath(path)
    descriptor = os.open(resolved, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("helper executable is not a regular file")
        if info.st_uid not in (SYSTEM_UID, os.getuid()) or info.st_mode & 0o022:
            raise ValueError("helper executable has unsafe ownership or permissions")
    finally:
        os.close(descriptor)
    return resolved


def child_setup(parent: int) -> None:
    os.setsid()
    set_parent_death_signal(parent)


def signal_group(process: subprocess.Popen[bytes], sig: int) -> None:
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def main() -> int:
    parent = os.getppid()
    requested_stop = False

    def request_stop(_signum: int, _frame: object) -> None:
        nonlocal requested_stop
        requested_stop = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--timeout-ms", type=int, required=True)
    parser.add_argument("--stdout-limit", type=int, required=True)
    parser.add_argument("--stderr-limit", type=int, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        return fail("missing helper command")
    if not 100 <= args.timeout_ms <= MAX_TIMEOUT_MS:
        return fail("invalid helper timeout")
    if not 0 <= args.stdout_limit <= MAX_OUTPUT or not 0 <= args.stderr_limit <= MAX_OUTPUT:
        return fail("invalid helper output limit")

    try:
        args.command[0] = trusted_executable(args.command[0])
        set_parent_death_signal(parent)
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "prctl(PR_SET_CHILD_SUBREAPER) failed")
    except (OSError, ValueError) as error:
        return fail(str(error))

    environment = {
        key: value
        for key, value in os.environ.items()
        if key
        in {
            "DBUS_SESSION_BUS_ADDRESS",
            "DISPLAY",
            "GDK_BACKEND",
            "HOME",
            "LANG",
            "LC_ALL",
            "PATH",
            "WAYLAND_DISPLAY",
            "XDG_CURRENT_DESKTOP",
            "XDG_DATA_DIRS",
            "XDG_RUNTIME_DIR",
        }
    }
    environment["PATH"] = "/usr/bin"
    environment.pop("PYTHONHOME", None)
    environment.pop("PYTHONPATH", None)

    supervisor_pid = os.getpid()
    if requested_stop:
        return fail("helper cancelled", 143)
    try:
        process = subprocess.Popen(
            args.command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            close_fds=True,
            preexec_fn=lambda: child_setup(supervisor_pid),
        )
    except OSError as error:
        return fail(f"could not start helper: {error.strerror}", 126)

    selector = selectors.DefaultSelector()
    streams = {
        process.stdout: (bytearray(), args.stdout_limit, "stdout"),
        process.stderr: (bytearray(), args.stderr_limit, "stderr"),
    }
    for stream in streams:
        assert stream is not None
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ)

    started = time.monotonic()
    stop_reason = ""
    termination_started = 0.0
    output_overflow = ""

    while selector.get_map() or process.poll() is None:
        now = time.monotonic()
        if not stop_reason and requested_stop:
            stop_reason = "cancelled"
        if not stop_reason and (now - started) * 1000 >= args.timeout_ms:
            stop_reason = "timed out"
        if not stop_reason and output_overflow:
            stop_reason = f"{output_overflow} limit exceeded"
        # Descendants can retain the pipes after the direct helper exits.
        # Always stop the group, including when its leader has already died.
        if stop_reason:
            if termination_started == 0.0:
                termination_started = now
                signal_group(process, signal.SIGTERM)
            elif now - termination_started >= TERM_GRACE_SECONDS:
                signal_group(process, signal.SIGKILL)
                if now - termination_started >= TERM_GRACE_SECONDS + 0.5:
                    break

        for key, _mask in selector.select(timeout=0.05):
            stream = key.fileobj
            buffer, limit, label = streams[stream]
            try:
                chunk = os.read(stream.fileno(), 4096)
            except BlockingIOError:
                continue
            if not chunk:
                selector.unregister(stream)
                stream.close()
                continue
            remaining = limit - len(buffer)
            if remaining > 0:
                buffer.extend(chunk[:remaining])
            if len(chunk) > remaining and not output_overflow:
                output_overflow = label

    return_code = process.wait()
    # The helper normally waits for its own children. If it was killed
    # unexpectedly, do not leave any descendant alive in its process group.
    signal_group(process, signal.SIGTERM)
    time.sleep(0.05)
    signal_group(process, signal.SIGKILL)
    selector.close()
    for stream in streams:
        stream.close()
    # Adopt and reap orphaned descendants instead of relying on the session's
    # init process to clean up zombies. Cleanup itself has a deadline.
    reap_deadline = time.monotonic() + 0.5
    while time.monotonic() < reap_deadline:
        try:
            child, _status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if child == 0:
            time.sleep(0.01)
    stdout_data = bytes(streams[process.stdout][0])
    stderr_data = bytes(streams[process.stderr][0])

    if output_overflow:
        return fail(f"helper {output_overflow} limit exceeded", 70)
    if stop_reason:
        return fail(f"helper {stop_reason}", 124 if stop_reason == "timed out" else 143)

    if stdout_data:
        sys.stdout.buffer.write(stdout_data)
        sys.stdout.buffer.flush()
    if stderr_data:
        sys.stderr.buffer.write(stderr_data)
        sys.stderr.buffer.flush()
    return return_code if return_code >= 0 else 128 - return_code


if __name__ == "__main__":
    raise SystemExit(main())
