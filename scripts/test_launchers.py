#!/usr/bin/env python3
"""No-model launcher regressions. Uses fake commands; never compiles or loads weights."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('serve', ROOT / 'scripts/serve.py')
serve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(serve)


build_spec = importlib.util.spec_from_file_location('build', ROOT / 'scripts/build.py')
build = importlib.util.module_from_spec(build_spec)
build_spec.loader.exec_module(build)


class Launchers(unittest.TestCase):
    def test_both_profiles_clear_inherited_overrides(self):
        for profile, experts, mode in [('30gb', '152', 'off'), ('78gb', '512', 'both')]:
            with patch.dict(os.environ, {'SLOTSTREAM_BAD': '1', 'MLX_BAD': '1', 'SS_DEBUG_BAD': '1'}):
                cfg, binary, env, common, argv = serve.configuration(profile, '.', 11435)
            self.assertNotIn('SLOTSTREAM_BAD', env)
            self.assertNotIn('MLX_BAD', env)
            self.assertNotIn('SS_DEBUG_BAD', env)
            self.assertEqual(env['SLOTSTREAM_FULL_RESIDENT_MODE'], mode)
            self.assertEqual(common[common.index('--experts-per-layer') + 1], experts)
            self.assertEqual(binary, ROOT / '.build/release/slotstream')
            self.assertIn('--no-prefix-cache', argv)

    def test_build_stops_before_swift_when_busy_or_check_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            for status in [0, 2, 127]:
                fake = directory / 'pgrep'
                fake.write_text('#!/bin/sh\nexit ' + str(status) + '\n')
                fake.chmod(0o755)
                marker = directory / 'swift-called'
                swift = directory / 'swift'
                swift.write_text('#!/bin/sh\ntouch "$BUILD_TEST_MARKER"\nexit 99\n')
                swift.chmod(0o755)
                env = dict(os.environ, PATH=str(directory) + ':' + os.environ['PATH'], BUILD_TEST_MARKER=str(marker))
                result = subprocess.run(['bash', 'scripts/build.sh', '30gb'], cwd=ROOT,
                                        env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(marker.exists())
                self.assertTrue('before building' in result.stderr or 'Cannot verify' in result.stderr)

    def test_model_build_lock_contention_and_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lock'
            with build.model_build_lock(path):
                with self.assertRaises(RuntimeError):
                    with build.model_build_lock(path):
                        self.fail('second lock unexpectedly acquired')
            # Exception paths release the lock as well as normal return.
            with self.assertRaises(ValueError):
                with build.model_build_lock(path):
                    raise ValueError('simulated build failure')
            with build.model_build_lock(path):
                pass

    def test_build_child_keeps_exclusion_after_wrapper_closes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lock'
            child = None
            try:
                with build.model_build_lock(path) as fd:
                    child = subprocess.Popen(
                        [os.sys.executable, '-c', 'import sys; print("ready", flush=True); sys.stdin.read()'],
                        pass_fds=(fd,), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
                    self.assertEqual(child.stdout.readline().strip(), 'ready')
                with self.assertRaises(RuntimeError):
                    with build.model_build_lock(path):
                        self.fail('build child lost exclusion')
                child.communicate(timeout=5)
                with build.model_build_lock(path):
                    pass
            finally:
                if child is not None and child.poll() is None:
                    child.kill()
                    child.communicate()

    def test_model_build_lock_rejects_links(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lock'
            target = Path(directory) / 'target'
            target.write_text('untouched')
            path.symlink_to(target)
            with self.assertRaises(OSError):
                with build.model_build_lock(path):
                    self.fail('symlink accepted')
            path.unlink()
            os.link(target, path)
            with self.assertRaises(RuntimeError):
                with build.model_build_lock(path):
                    self.fail('hard link accepted')
            self.assertEqual(target.read_text(), 'untouched')

    def test_invalid_port_rejected_without_preflight(self):
        for port in ['0', '65536', '-1']:
            result = subprocess.run(['python3', str(ROOT / 'scripts/serve.py'), '--dry-run', '--port', port],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('port must be', result.stderr)

    def test_watchdog_is_explicit_and_validated(self):
        for timeout in ['-1', 'nan', 'inf']:
            result = subprocess.run(['python3', str(ROOT / 'scripts/serve.py'), '--dry-run', '--stall-timeout-seconds='+timeout], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('finite and nonnegative', result.stderr)
        result = subprocess.run(['python3', str(ROOT / 'scripts/serve.py'), '--dry-run', '--stall-timeout-seconds', '180'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        import json
        argv = json.loads(result.stdout)['argv']
        self.assertEqual(argv[argv.index('--stall-timeout-seconds') + 1], '180.0')


if __name__ == '__main__':
    unittest.main()
