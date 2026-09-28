"""Bridge tests: scheduler access from foreign Python threads.

Runs as its own process - bridge behavior is sensitive to in-process
history (see notes/scheduler-spike.md), so these do not share the
main suite's process.

    ./build.sh
    python3 test/test_bridge.py
"""

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

    # foreign thread: full scheduler access via AdoptingContext
    ticks = [0]
    stop = [False]

    def spinner():
        while not stop[0]:
            ticks[0] += 1

    bs = threading.Thread(target=spinner)
    bs.start()
    foreign_result = []
    errors = []

    def bridge_worker():
        try:
            foreign_result.append(pycr.bridge_sleep(0.2))
            foreign_result.append(pycr.bridge_nano(0.05))
            foreign_result.append(len(pycr.adopt_read("/etc/hostname")))
            pycr.bridge_raise()
        except ValueError:
            foreign_result.append("raise-ok")
        except Exception as error:  # noqa: BLE001
            errors.append(error)

    fw = threading.Thread(target=bridge_worker)
    fw.start()
    fw.join()
    stop[0] = True
    bs.join()
    assert not errors, errors
    assert foreign_result[0] == "slept 0.2s on the bridge"
    assert foreign_result[1] == "nano-slept"
    assert foreign_result[2] > 0
    assert foreign_result[3] == "raise-ok"
    assert ticks[0] > 100_000, "GIL was not released during the adopted wait"
    print(f"foreign thread: sleep + IO + exceptions via adopted context, spinner ran {ticks[0]} ticks")

    # concurrent foreign callers: each gets its own adopted context
    concurrent_results = []
    concurrent_errors = []

    def concurrent_worker(n):
        try:
            concurrent_results.append(pycr.bridge_sleep(0.02))
        except Exception as error:  # noqa: BLE001
            concurrent_errors.append(error)

    callers = [threading.Thread(target=concurrent_worker, args=(n,)) for n in range(3)]
    for thread in callers:
        thread.start()
    for thread in callers:
        thread.join()
    assert not concurrent_errors, concurrent_errors
    assert concurrent_results == ["slept 0.02s on the bridge"] * 3
    print("concurrent foreign callers: each has its own adopted context")

    assert pycr.pinned_count() == 0
    print("ALL BRIDGE TESTS PASSED")


if __name__ == "__main__":
    main()
