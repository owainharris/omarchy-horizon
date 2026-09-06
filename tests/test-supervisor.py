#!/usr/bin/python3

from __future__ import annotations

import json
import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parent.parent
SUPERVISOR = REPOSITORY / "supervisor.py"


def command(timeout: int, stdout_limit: int, stderr_limit: int, child: list[str]) -> list[str]:
    return [
        "/usr/bin/python3",
        str(SUPERVISOR),
        "--timeout-ms",
        str(timeout),
        "--stdout-limit",
        str(stdout_limit),
        "--stderr-limit",
        str(stderr_limit),
        "--",
        *child,
    ]


class SupervisorTests(unittest.TestCase):
    def test_exited_leader_with_term_resistant_pipe_holder_is_reaped(self) -> None:
        with tempfile.TemporaryDirectory(prefix="span-supervisor-test.") as directory:
            pid_file = Path(directory) / "pid"
            script = (
                "import os,pathlib,signal,sys,time\n"
                "if os.fork() == 0:\n"
                " signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                " pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\n"
                " time.sleep(30)\n"
            )
            result = subprocess.run(
                command(300, 128, 128, ["/usr/bin/python3", "-c", script, str(pid_file)]),
                capture_output=True, text=True, check=False, timeout=5,
            )
            self.assertEqual(result.returncode, 124)
            self.assertIn("timed out", result.stderr)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)

    def test_normal_exit_reaps_descendants_without_open_pipes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="span-supervisor-test.") as directory:
            pid_file = Path(directory) / "pid"
            script = (
                "import pathlib,subprocess,sys; "
                "p=subprocess.Popen(['/usr/bin/sleep','30'], "
                "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
                "pathlib.Path(sys.argv[1]).write_text(str(p.pid))"
            )
            result = subprocess.run(
                command(2000, 128, 128, ["/usr/bin/python3", "-c", script, str(pid_file)]),
                capture_output=True, text=True, check=False, timeout=5,
            )
            self.assertEqual(result.returncode, 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)

    def test_child_receives_only_the_minimal_environment(self) -> None:
        environment = dict(os.environ)
        environment["SPAN_WALLPAPER_SHOULD_NOT_LEAK"] = "secret"
        result = subprocess.run(
            command(
                2000,
                4096,
                128,
                ["/usr/bin/python3", "-c", "import json,os; print(json.dumps(sorted(os.environ)))"],
            ),
            capture_output=True,
            text=True,
            check=False,
            env=environment,
        )
        self.assertEqual(result.returncode, 0)
        keys = json.loads(result.stdout)
        self.assertNotIn("SPAN_WALLPAPER_SHOULD_NOT_LEAK", keys)
        self.assertTrue(set(keys) <= {
            "DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "GDK_BACKEND", "HOME", "LANG", "LC_ALL",
            "PATH", "WAYLAND_DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_DATA_DIRS", "XDG_RUNTIME_DIR"
        })

    def test_output_is_bounded_before_forwarding(self) -> None:
        result = subprocess.run(
            command(2000, 128, 128, ["/usr/bin/python3", "-c", "print('x' * 4096)"]),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 70)
        self.assertLessEqual(len(result.stdout), 128)
        self.assertIn("stdout limit exceeded", result.stderr)

    def test_timeout_kills_descendant_process_group(self) -> None:
        with tempfile.TemporaryDirectory(prefix="span-supervisor-test.") as directory:
            pid_file = Path(directory) / "pid"
            script = (
                "import pathlib,subprocess,time,sys; "
                "p=subprocess.Popen(['/usr/bin/sleep','30']); "
                "pathlib.Path(sys.argv[1]).write_text(str(p.pid)); "
                "time.sleep(30)"
            )
            result = subprocess.run(
                command(300, 128, 128, ["/usr/bin/python3", "-c", script, str(pid_file)]),
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )
            self.assertEqual(result.returncode, 124)
            child_pid = int(pid_file.read_text())
            time.sleep(0.1)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)

    def test_parent_cancellation_kills_descendant_process_group(self) -> None:
        with tempfile.TemporaryDirectory(prefix="span-supervisor-test.") as directory:
            pid_file = Path(directory) / "pid"
            script = (
                "import pathlib,subprocess,time,sys; "
                "p=subprocess.Popen(['/usr/bin/sleep','30']); "
                "pathlib.Path(sys.argv[1]).write_text(str(p.pid)); "
                "time.sleep(30)"
            )
            process = subprocess.Popen(
                command(5000, 128, 128, ["/usr/bin/python3", "-c", script, str(pid_file)]),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for _attempt in range(50):
                if pid_file.exists():
                    break
                time.sleep(0.02)
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143)
            child_pid = int(pid_file.read_text())
            time.sleep(0.1)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)


if __name__ == "__main__":
    unittest.main()
