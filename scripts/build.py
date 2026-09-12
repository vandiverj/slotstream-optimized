#!/usr/bin/env python3
"""Build the shared engine while holding the model process's exclusion lock."""
import contextlib
import fcntl
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


@contextlib.contextmanager
def model_build_lock(path=None):
    path = path or Path('/tmp') / ('slotstream-model-%d.lock' % os.getuid())
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            raise RuntimeError('model/build lock must be an owned regular file with a single link')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('a model or build already holds the process lock; stop it before building') from None
        # Commands inherit the descriptor so killing only this wrapper does not
        # release exclusion while its Swift build child is still running.
        yield fd
    finally:
        os.close(fd)


def main():
    if len(sys.argv) > 2 or (len(sys.argv) == 2 and sys.argv[1] not in ('30gb', '78gb')):
        raise RuntimeError('Usage: scripts/build.sh [78gb|30gb]')
    profile = sys.argv[1] if len(sys.argv) == 2 else '78gb'
    # Also reject older binaries/check tools that may not use the lock.
    for name in ('slotstream', 'slotstream-checks'):
        result = subprocess.run(['pgrep', '-x', name], stdout=subprocess.DEVNULL)
        if result.returncode == 0:
            raise RuntimeError('Stop %s before building; never overlap a model and a build.' % name)
        if result.returncode != 1:
            raise RuntimeError('Cannot verify that model processes are stopped (pgrep: %d).' % result.returncode)
    with model_build_lock() as fd:
        def run(command):
            subprocess.run(command, cwd=ROOT, check=True, pass_fds=(fd,))
        run([sys.executable, 'scripts/verify_sources.py'])
        run(['swift', 'build', '--package-path', str(ROOT), '--disable-automatic-resolution',
             '--skip-update', '-c', 'release', '--jobs', '4'])
        run(['Tools/fetch_metallib.sh'])
        shutil.copyfile(ROOT / 'Tools/lib/mlx-0.31.1.metallib', ROOT / '.build/release/mlx.metallib')
    print('Built %s: %s' % (profile, ROOT / '.build/release/slotstream'))


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print('Build failed: %s' % error, file=sys.stderr)
        raise SystemExit(1)
