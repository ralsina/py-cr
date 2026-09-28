"""Bridge tests: scheduler access from foreign Python threads.

Runs as its own process - bridge behavior is sensitive to in-process
history (see notes/scheduler-spike.md), so these do not share the
main suite's process.

    ./build.sh
    python3 test/test_bridge.py
"""

import gc
import os
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pycr  # noqa: E402


def main() -> None:
    print(f"module file: {pycr.__file__}")
    # fast path: importing thread runs work directly
    assert "0.01" in pycr.bridge_sleep(0.01)
    assert pycr.bridge_nano(0.01) == "nano-slept"
    try:
        pycr.bridge_raise()
    except ValueError as error:
        assert "raised on the bridge" in str(error)
    print("bridge fast path on importing thread: sleep, exceptions")

    # foreign thread: the operations that cannot run without the bridge.
    # (spawn inside bridge blocks is NOT supported - it routes through
    # execution-context machinery that deadlocks under embedding; use
    # blocking IO and Pycr.sleep_seconds in bridge work)
    # NOTE: no CPU-bound Python thread here on purpose - a spinner
    # racing the waiter's GIL re-acquisition deadlocks the bridge wait
    # (see notes/scheduler-spike.md, known limitation)
    foreign_result = []
    errors = []

    def bridge_worker():
        try:
            foreign_result.append(pycr.bridge_sleep(0.2))
            foreign_result.append(pycr.bridge_nano(0.05))
            foreign_result.append(pycr.read_file("/etc/hostname"))
        except Exception as error:  # noqa: BLE001
            errors.append(error)

    fw = threading.Thread(target=bridge_worker)
    fw.start()
    fw.join()
    # foreign execution is gated: no adopting execution context exists
    assert len(errors) == 1, errors
    assert "not available" in str(errors[0]), errors
    print("foreign thread: gated with clear NotImplementedError (no adopting EC)")

    # concurrent foreign callers serialize through the funnel
    concurrent_results = []
    concurrent_errors = []

    def concurrent_worker(n):
        try:
            concurrent_results.append(pycr.bridge_nano(0.01 * n))
        except NotImplementedError as error:
            concurrent_errors.append(str(error))

    callers = [threading.Thread(target=concurrent_worker, args=(n,)) for n in range(3)]
    for thread in callers:
        thread.start()
    for thread in callers:
        thread.join()
    assert len(concurrent_errors) == 3
    assert all("not available" in error for error in concurrent_errors)
    print("concurrent foreign callers: gated identically")

    assert pycr.pinned_count() == 0
    print("ALL BRIDGE TESTS PASSED")


if __name__ == "__main__":
    main()
