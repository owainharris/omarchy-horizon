#!/usr/bin/python3

from __future__ import annotations

import json
import hashlib
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPOSITORY))

import helper  # noqa: E402


class HelperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="span-wallpaper-test.")
        self.root = Path(self.temporary.name) / "state"
        self.source = Path(self.temporary.name) / "source.png"
        subprocess.run(
            ["/usr/bin/magick", "-size", "100x200", "gradient:#ff0000-#0000ff", "-rotate", "90", str(self.source)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.source.chmod(0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_import_crop_state_and_clear(self) -> None:
        geometry = [
            {"name": "LEFT", "x": 0, "y": 0, "width": 100, "height": 100},
            {"name": "RIGHT", "x": 120, "y": 0, "width": 100, "height": 100},
        ]
        with helper.StateStore(self.root) as store:
            retained = helper.import_source(store, str(self.source))
            self.assertTrue(Path(retained).is_file())
            helper.crop(store, retained, json.dumps(geometry), "fill")
            state = store.read_state()
            self.assertEqual(state["scaleMode"], "fill")
            self.assertEqual(state["bounds"], {"x": 0, "y": 0, "width": 220, "height": 100})
            self.assertEqual(len(state["monitors"]), 2)
            for monitor in state["monitors"]:
                dimensions = subprocess.check_output(
                    ["/usr/bin/magick", "identify", "-format", "%wx%h", monitor["file"]], text=True
                )
                self.assertEqual(dimensions, "100x100")
            store.publish_state(dict(helper.EMPTY_STATE))
            self.assertEqual(store.read_state(), helper.EMPTY_STATE)
            self.assertEqual(stat.S_IMODE(os.fstat(store.fd).st_mode), 0o700)

    def test_source_symlink_fifo_and_oversize_are_rejected(self) -> None:
        symlink = Path(self.temporary.name) / "linked.png"
        symlink.symlink_to(self.source)
        fifo = Path(self.temporary.name) / "image.fifo"
        os.mkfifo(fifo, 0o600)
        oversized = Path(self.temporary.name) / "large.img"
        with oversized.open("wb") as stream:
            stream.truncate(helper.MAX_SOURCE_BYTES + 1)
        oversized.chmod(0o600)

        for candidate in (symlink, fifo, oversized):
            with self.subTest(candidate=candidate.name), helper.StateStore(self.root) as store:
                with self.assertRaises(helper.HelperError):
                    helper.import_source(store, str(candidate))

    def test_state_symlink_and_oversize_are_rejected_before_read(self) -> None:
        with helper.StateStore(self.root) as store:
            pass
        state_path = self.root / "state.json"
        state_path.symlink_to("/etc/passwd")
        with helper.StateStore(self.root) as store, self.assertRaises(OSError):
            store.read_state()
        state_path.unlink()
        state_path.write_bytes(b"x" * (helper.MAX_STATE_BYTES + 1))
        state_path.chmod(0o600)
        with helper.StateStore(self.root) as store, self.assertRaises(helper.HelperError):
            store.read_state()

    def test_geometry_and_state_cardinality_are_bounded(self) -> None:
        with self.assertRaises(helper.HelperError):
            helper.normalize_monitors(
                [{"name": f"DP-{index}", "x": index, "y": 0, "width": 1, "height": 1} for index in range(33)]
            )
        with self.assertRaises(helper.HelperError):
            helper.normalize_monitors([{"name": "<img src=file:///etc/passwd>", "x": 0, "y": 0, "width": 40000, "height": 1}])

    def test_private_directory_cleanup_rewinds_shared_offset(self) -> None:
        with helper.StateStore(self.root) as store:
            name, descriptor = store.create_dir(".work-")
            child = os.open("scratch", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=descriptor)
            os.close(child)
            self.assertEqual(os.listdir(descriptor), ["scratch"])
            helper.remove_private_dir(store.fd, name, descriptor)
            self.assertFalse((self.root / name).exists())

    def test_absolute_and_parent_relative_state_reads_are_rejected(self) -> None:
        with helper.StateStore(self.root) as store:
            for path in (str(self.source), "../source.png", "sources/../../source.png"):
                with self.subTest(path=path), self.assertRaises(helper.HelperError):
                    store.open_relative_file(path, helper.MAX_SOURCE_BYTES)

    def test_existing_retained_fifo_does_not_block_import(self) -> None:
        with helper.StateStore(self.root) as store:
            directory = store.ensure_dir("sources")
            os.close(directory)
        digest = hashlib.sha256(self.source.read_bytes()).hexdigest()
        os.mkfifo(self.root / "sources" / f"{digest}.img", 0o600)
        script = (
            "import helper,sys; from pathlib import Path; "
            "store=helper.StateStore(Path(sys.argv[1])); "
            "helper.import_source(store,sys.argv[2])"
        )
        result = subprocess.run(
            ["/usr/bin/python3", "-c", script, str(self.root), str(self.source)],
            cwd=REPOSITORY, capture_output=True, text=True, timeout=3,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("retained image has unsafe metadata", result.stderr)

    def test_crop_pixels_match_canvas_in_all_modes(self) -> None:
        layouts = [
            [{"name": "SOLO", "x": -40, "y": 20, "width": 60, "height": 80}],
            [
                {"name": "LEFT", "x": -40, "y": -10, "width": 60, "height": 80},
                {"name": "RIGHT", "x": 30, "y": 10, "width": 50, "height": 60},
            ],
        ]
        with helper.StateStore(self.root) as store:
            retained = helper.import_source(store, str(self.source))
            for layout in layouts:
                for mode in ("fill", "fit", "stretch"):
                    with self.subTest(outputs=len(layout), mode=mode):
                        helper.crop(store, retained, json.dumps(layout), mode)
                        state = store.read_state()
                        bounds = state["bounds"]
                        size = f"{bounds['width']}x{bounds['height']}"
                        resize = size + {"fill": "^", "fit": "", "stretch": "!"}[mode]
                        for monitor in state["monitors"]:
                            geometry = (f"{monitor['width']}x{monitor['height']}"
                                        f"+{monitor['x'] - bounds['x']}+{monitor['y'] - bounds['y']}")
                            expected = subprocess.check_output([
                                "/usr/bin/magick", str(self.source), "-resize", resize,
                                "-gravity", "center", "-background", "black", "-extent", size,
                                "+repage", "-gravity", "NorthWest", "-crop", geometry,
                                "+repage", "-depth", "8", "rgb:-",
                            ])
                            actual = subprocess.check_output([
                                "/usr/bin/magick", monitor["file"], "-depth", "8", "rgb:-",
                            ])
                            self.assertEqual(actual, expected)

    def test_animated_source_uses_first_frame(self) -> None:
        animation = Path(self.temporary.name) / "animated.gif"
        subprocess.run([
            "/usr/bin/magick", "-size", "8x8", "xc:red", "xc:blue", str(animation),
        ], check=True)
        animation.chmod(0o600)
        with helper.StateStore(self.root) as store:
            retained = helper.import_source(store, str(animation))
            helper.crop(store, retained, json.dumps([
                {"name": "ONE", "x": 0, "y": 0, "width": 8, "height": 8},
            ]), "fill")
            pixels = subprocess.check_output([
                "/usr/bin/magick", store.read_state()["monitors"][0]["file"],
                "-depth", "8", "rgb:-",
            ])
            self.assertEqual(pixels, bytes([255, 0, 0]) * 64)


if __name__ == "__main__":
    unittest.main()
