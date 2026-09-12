#!/usr/bin/env python3
"""Process recovery tests using tiny fake children, never models or weights."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

from supervisor import supervise


class Recovery(unittest.TestCase):
    def test_success_is_not_restarted(self):
        checks = []
        code = supervise([sys.executable, '-c', 'pass'], dict(os.environ), lambda: checks.append(1), delays=(0,))
        self.assertEqual(code, 0)
        self.assertEqual(len(checks), 1)

    def test_persistent_failure_exhausts_budget(self):
        checks = []
        code = supervise([sys.executable, '-c', 'raise SystemExit(7)'], dict(os.environ), lambda: checks.append(1), delays=(0,))
        self.assertEqual(code, 7)
        self.assertEqual(len(checks), 4)

    def test_failed_preflight_prevents_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'started'
            def fail():
                raise RuntimeError('headroom unavailable')
            with self.assertRaisesRegex(RuntimeError, 'headroom'):
                supervise([sys.executable, '-c', 'from pathlib import Path; Path(__import__("sys").argv[1]).touch()', str(marker)], dict(os.environ), fail)
            self.assertFalse(marker.exists())

    def test_restart_waits_for_child_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'pid'
            checks = []
            def check():
                if marker.exists():
                    with self.assertRaises(ProcessLookupError):
                        os.kill(int(marker.read_text()), 0)
                checks.append(1)
            command = [sys.executable, '-c', 'import os,sys; from pathlib import Path; Path(sys.argv[1]).write_text(str(os.getpid())); raise SystemExit(9)', str(marker)]
            self.assertEqual(supervise(command, dict(os.environ), check, max_restarts=1, delays=(0,)), 9)
            self.assertEqual(len(checks), 2)

    def test_parent_stop_forwards_and_does_not_restart(self):
        # A pipe handshake makes the signal occur only after the fake child
        # installs its handler. No sleeps or model process required.
        script = '''import os,sys
from supervisor import supervise
child = "import signal,sys,time; signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); print('ready', flush=True); time.sleep(120)"
sys.exit(supervise([sys.executable,'-c',child],dict(os.environ),lambda:None,delays=(0,)))
'''
        process = subprocess.Popen([sys.executable, '-c', script], cwd=Path(__file__).parent,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), 'ready')
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertNotIn('restart', stdout)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
    def test_unresponsive_child_is_killed_on_stop(self):
        script = '''import os,sys
from supervisor import supervise
child = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(120)"
sys.exit(supervise([sys.executable,'-c',child],dict(os.environ),lambda:None,delays=(0,),stop_timeout=.05))
'''
        process = subprocess.Popen([sys.executable, '-c', script], cwd=Path(__file__).parent,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), 'ready')
            process.terminate()
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 124)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == '__main__':
    unittest.main()
