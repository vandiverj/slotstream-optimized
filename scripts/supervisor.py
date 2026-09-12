"""Bounded process recovery. Never replay requests or overlap model children."""
import signal
import subprocess
import threading


def supervise(command, env, preflight, max_restarts=3, delays=(5, 10, 20), stop_timeout=45):
    stopped = threading.Event()
    child = None

    def stop(number, _frame):
        stopped.set()
        if child is not None and child.poll() is None:
            try:
                child.send_signal(number)
            except ProcessLookupError:
                pass

    previous = {number: signal.signal(number, stop) for number in (signal.SIGTERM, signal.SIGINT)}
    try:
        for attempt in range(max_restarts + 1):
            if stopped.is_set():
                return 0
            preflight()  # Includes process exclusion and fresh memory headroom.
            if stopped.is_set():
                return 0
            child = subprocess.Popen(command, env=env)
            # A stop arriving between the last check and Popen still reaches
            # the child; ordinary crashes are always reaped before restarting.
            if stopped.is_set():
                child.terminate()
            while True:
                try:
                    code = child.wait(timeout=1)
                    break
                except subprocess.TimeoutExpired:
                    if stopped.is_set():
                        try:
                            code = child.wait(timeout=stop_timeout)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait()
                            return 124
                        break
            child = None
            if stopped.is_set() or code == 0 or attempt == max_restarts:
                return code if code >= 0 else 128 - code
            delay = delays[min(attempt, len(delays) - 1)]
            print('Server failed (exit %d); restart %d/%d in %d seconds. Requests are not replayed.'
                  % (code, attempt + 1, max_restarts, delay), flush=True)
            if stopped.wait(delay):
                return 0
        return 1
    finally:
        # An exception in supervision must not leave a model orphaned.
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=stop_timeout)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for number, handler in previous.items():
            signal.signal(number, handler)
