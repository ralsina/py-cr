"""Tests for the pycr Crystal extension.

Run from the repo root after building:

    ./build.sh
    python3 test/test_pycr.py
"""

import gc
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pycr  # noqa: E402


def wait_pins(target=0, rounds=100):
    """Wait for pins to drain: under free-threaded CPython, deallocs
    are deferred (QSBR), so pins drop asynchronously."""
    for _ in range(rounds):
        gc.collect()
        pycr.gc()
        if pycr.pinned_count() == target:
            return True
        time.sleep(0.005)
    return pycr.pinned_count() == target


def expect_type_error(call, label):
    try:
        call()
    except TypeError:
        pass
    else:
        raise SystemExit(f"FAIL: {label} did not raise TypeError")


def main() -> None:
    print(f"module file: {pycr.__file__}")

    # 1. CPython dlopened the Crystal .so and ran PyInit_pycr
    assert pycr.hello() == "Hello from Crystal!"
    print(f"hello() -> {pycr.hello()!r}")

    # 2. Arguments cross into Crystal and results come back
    assert pycr.echo("world") == "Hello, world!"
    assert pycr.echo("ñ") == "Hello, ñ!"
    print(f"echo('world') -> {pycr.echo('world')!r}")

    assert pycr.length("crystal") == 7
    print(f"length('crystal') -> {pycr.length('crystal')}")

    print(f"version() -> {pycr.version()!r}")

    # 3. Crystal exceptions become the right Python exceptions
    try:
        pycr.boom()
    except RuntimeError as error:
        print(f"boom() raised RuntimeError: {error}")
        assert "boom from Crystal" in str(error)
    else:
        raise SystemExit("FAIL: boom() did not raise")

    try:
        pycr.fail_value()
    except ValueError as error:
        print(f"fail_value() raised ValueError: {error}")
    else:
        raise SystemExit("FAIL: fail_value() did not raise ValueError")

    try:
        pycr.fail_key()
    except KeyError as error:
        print(f"fail_key() raised KeyError: {error}")
    else:
        raise SystemExit("FAIL: fail_key() did not raise KeyError")

    # 4. Boehm GC cycles while running inside CPython
    assert pycr.churn(1) > 400_000  # allocation-triggered collections
    bytes_allocated = pycr.stress(4)
    print(f"stress(4) allocated {bytes_allocated} bytes, ran GC.collect, survived")
    assert bytes_allocated > 0

    # 5. Pin/unpin registry: a Crystal object only referenced by Python
    #    survives Boehm collections, and gets unpinned when Python drops it
    capsule = pycr.box("alive across GC cycles")
    assert pycr.pinned_count() == 1
    pycr.stress(2)  # forces Boehm collections with the string only pinned
    assert pycr.unbox(capsule) == "alive across GC cycles"
    print("box/unbox kept a Crystal string alive across GC cycles")

    del capsule
    gc.collect()
    assert pycr.pinned_count() == 0
    print("capsule destructor unpinned the string")

    # 6. Typed conversions round-trip
    assert pycr.add(2, 40) == 42
    assert pycr.add(2 ** 40, 2 ** 40) == 2 ** 41
    assert pycr.is_big(2_000_000) is True
    assert pycr.is_big(12) is False
    assert abs(pycr.mean([1.0, 2.0, 3.5]) - 13.0 / 6.0) < 1e-12
    assert pycr.double_all([1, 2, 3]) == [2, 4, 6]
    assert pycr.word_count(["a", "b", "a"]) == {"a": 2, "b": 1}
    assert pycr.merge_counts({"a": 1, "b": 2}, {"b": 3, "c": 4}) == {"a": 1, "b": 5, "c": 4}
    assert pycr.min_max([3, 1, 4, 1, 5]) == (1, 5)
    assert pycr.nothing() is None
    print("conversions: ints, floats, bools, strings, lists, dicts, tuples, None round-trip")

    # conversion failure paths surface as the right Python exceptions
    expect_type_error(lambda: pycr.add(1), "add() with one argument")
    expect_type_error(lambda: pycr.add("x", 1), "add() with a str")
    expect_type_error(lambda: pycr.mean("nope"), "mean() with a str")
    expect_type_error(lambda: pycr.merge_counts("nope", {}), "merge_counts() with a str")

    try:
        pycr.mean([])
    except ValueError as error:
        print(f"mean([]) raised ValueError: {error}")
    else:
        raise SystemExit("FAIL: mean([]) did not raise")

    # 7. Keyword arguments everywhere a default (or any arg) exists
    assert pycr.add(first=2, second=40) == 42
    assert pycr.add(2, second=40) == 42
    assert pycr.mean(numbers=[1.0, 2.0]) == 1.5
    assert pycr.echo(name="kw") == "Hello, kw!"
    try:
        pycr.nope = 1
    except AttributeError:
        pass
    expect_type_error(lambda: pycr.hello(bogus=1), "hello() with a keyword")
    print("keyword arguments work (and bad ones raise TypeError)")

    # 8. Block-style class: methods, defaults, __repr__, attributes
    counter = pycr.Counter()
    assert counter.value() == 0
    assert counter.increment() == 1
    assert counter.increment(5) == 6
    assert counter.increment(amount=10) == 16
    assert counter.value() == 16
    assert repr(counter) == "Counter(count=16)"

    assert counter.count == 16          # pyattr read
    counter.count = 7                   # pyattr write
    assert counter.count == 7
    assert counter.value() == 7
    expect_type_error(lambda: setattr(counter, "count", "nope"), "count = str")
    try:
        del counter.count
    except NotImplementedError:
        pass
    else:
        raise SystemExit("FAIL: deleting count worked")

    assert counter.reset() is None
    assert counter.value() == 0
    print("Counter: methods, kwargs, __repr__, attributes all work")

    keyword_built = pycr.Counter(count=5)
    assert keyword_built.value() == 5
    del keyword_built
    started = pycr.Counter(10)
    assert pycr.pinned_count() == 2
    pycr.stress(2)  # Boehm cycles: instances are only reachable via the registry
    assert counter.value() == 0
    assert started.value() == 10
    print("Counter instances survived GC cycles while pinned")

    expect_type_error(lambda: pycr.Counter("ten"), "Counter('ten')")
    assert pycr.pinned_count() == 2  # failed constructors do not leak pins
    del counter, started
    gc.collect()
    assert pycr.pinned_count() == 0
    print("Counter dealloc unpinned both instances")

    # 9. Annotation-style class (discovered automatically by pyinit)
    greeter = pycr.Greeter()
    assert greeter.greetings == 0
    assert greeter.greet() == 1
    assert greeter.greet(word="howdy") == 2
    assert greeter.greetings == 2
    assert repr(greeter) == "Greeter(2)"

    kwargs_greeter = pycr.Greeter(greetings=10)
    assert kwargs_greeter.greetings == 10

    try:
        kwargs_greeter.greetings = 5
    except NotImplementedError:
        pass
    else:
        raise SystemExit("FAIL: read-only attribute was writable")

    assert pycr.pinned_count() == 2
    pycr.stress(1)
    assert greeter.greetings == 2
    del greeter, kwargs_greeter
    gc.collect()
    assert pycr.pinned_count() == 0
    print("Greeter (annotation style): constructor kwargs, read-only attr, __repr__ work")

    # 10. Second block-style class from the DSL
    word_counter = pycr.WordCounter()
    assert word_counter.add("hello") == 1
    assert word_counter.add("world") == 2
    assert word_counter.count() == 2
    assert repr(word_counter) == "2 words: hello, world"
    del word_counter
    gc.collect()
    print("WordCounter works")

    # 11. GIL release: a Python thread keeps counting while Crystal naps
    ticks = [0]
    stop = [False]

    def ticker():
        while not stop[0]:
            ticks[0] += 1

    ticker_thread = threading.Thread(target=ticker)
    ticker_thread.start()
    started_at = time.monotonic()
    pycr.nap(0.25)
    elapsed = time.monotonic() - started_at
    stop[0] = True
    ticker_thread.join()
    assert 0.2 < elapsed < 5.0
    assert ticks[0] > 10_000, f"only {ticks[0]} ticks: the GIL was never released"
    print(f"nap(0.25) released the GIL: ticker thread ran {ticks[0]} iterations")

    # 12. Threaded soak: several Python threads hammering the extension
    errors = []

    # Light concurrent operations only: collections are safe when a
    # single thread collects while the others are parked (see the
    # stress/churn sections), but two or more threads triggering Boehm
    # collections concurrently abort inside libgc's stop-the-world.
    # Documented as a known limitation with the evidence trail in
    # notes/boehm-vs-cpython-threads.md.
    def hammer():
        try:
            for _ in range(50):
                assert pycr.add(1, 2) == 3
                assert pycr.echo("t") == "Hello, t!"
                soak_counter = pycr.Counter(9)
                assert soak_counter.increment() == 10
                del soak_counter
        except Exception as error:  # noqa: BLE001
            errors.append(error)

    threads = [threading.Thread(target=hammer) for _ in range(4)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    gc.collect()
    assert not errors, f"threaded soak failed: {errors}"
    assert pycr.pinned_count() == 0
    print("threaded soak: 4 threads x 50 iterations, no errors, no leaked pins")

    # 13. Collection policy: automatic collection is off, memory is
    #     reclaimed only through the serialized entry point
    heap_before = pycr.heap()
    for _ in range(20):
        pycr.churn(5)  # ~50MB of garbage with collection disabled
    heap_grown = pycr.heap()
    pycr.gc()
    # GC_get_heap_size keeps swept pages on the free lists, so reclaimed
    # memory shows up as reuse: the same churn again must not grow it.
    for _ in range(20):
        pycr.churn(5)
    heap_reused = pycr.heap()
    assert heap_grown > heap_before, "churn did not grow the heap"
    assert heap_reused < heap_grown + 1_048_576, "gc() did not make memory reusable"
    print(f"collection policy: {heap_before//1024}KB -> {heap_grown//1024}KB, reusable after gc: {heap_reused//1024}KB")

    # 14. Concurrent collectors, serialized by the framework mutex
    def collector():
        for _ in range(200):
            pycr.gc()

    collectors = [threading.Thread(target=collector) for _ in range(4)]
    for thread in collectors:
        thread.start()
    for thread in collectors:
        thread.join()
    print("4 threads x 200 explicit concurrent collections: ok")

    # 15. The full melee: collectors and allocators racing a Python
    #     spinner and a GIL-released napper
    spinning = [True]
    spin_ticks = [0]

    def spinner():
        while spinning[0]:
            spin_ticks[0] += 1

    naps_done = [0]

    def napper():
        while spinning[0]:
            pycr.nap(0.001)
            naps_done[0] += 1

    melee = [threading.Thread(target=f) for f in
             (collector, spinner, napper, collector)]
    for thread in melee:
        thread.start()
    time.sleep(1.0)
    spinning[0] = False
    for thread in melee:
        thread.join()
    assert spin_ticks[0] > 100_000
    assert naps_done[0] > 10
    print(f"melee: collectors raced a spinner ({spin_ticks[0]} ticks) and a napper ({naps_done[0]} naps)")

    # 16. Python callables as arguments
    assert pycr.apply_func(lambda x: x * 2, 21) == 42
    assert pycr.apply_func(abs, -5) == 5
    assert pycr.map_ints(lambda v: v + 1, [1, 2, 3]) == [2, 3, 4]
    assert pycr.call_two(lambda a, b: a + b, "foo", "bar") == "foobar"
    assert pycr.call_plain(lambda: True) is True
    print("callables: lambdas, builtins, multi-arg and no-arg callbacks work")

    # callback exceptions propagate as themselves through the boundary
    for call, label in (
        (lambda: pycr.apply_func(lambda x: 1 / 0, 1), "ZeroDivisionError in callback"),
        (lambda: pycr.apply_func(lambda x: x + "s", 1), "TypeError in callback"),
        (lambda: pycr.apply_func(lambda x: x, 1, 2), "wrong arity callback"),
        (lambda: pycr.apply_func(42, 1), "non-callable argument"),
    ):
        try:
            call()
        except (ZeroDivisionError, TypeError):
            pass
        else:
            raise SystemExit(f"FAIL: {label} did not raise")

    # a callback that re-enters the extension
    assert pycr.apply_func(lambda x: pycr.add(x, 1), 41) == 42
    print("callback exceptions propagate; re-entrant callbacks work")

    # 17. Bytes in and out; str() wired to to_s
    assert pycr.hexdigest(b"hello") == b"hello".hex()
    assert pycr.repeat_bytes(b"ab", 3) == b"ababab"
    expect_type_error(lambda: pycr.hexdigest("not-bytes"), "hexdigest with str")
    print("bytes round-trip; non-bytes raise TypeError")

    counter = pycr.Counter(3)
    assert "Counter" in str(counter) and "count=3" in repr(counter)
    del counter
    print("str() is wired to to_s (Crystal default; override to_s to customize)")

    # 18. Memory soak: bounded RSS growth over a heavy mixed workload
    def rss_mb():
        with open("/proc/self/status") as status:
            for line in status:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) / 1024.0

    gc.collect()
    pycr.gc()
    start_rss = rss_mb()
    for round_number in range(300):
        pycr.churn(2)
        pycr.echo(f"soak {round_number}")
        soak_counter = pycr.Counter(round_number)
        soak_counter.increment()
        del soak_counter
        capsule = pycr.box("soak")
        pycr.unbox(capsule)
        del capsule
    pycr.gc()
    gc.collect()
    growth = rss_mb() - start_rss
    assert growth < 200, f"RSS grew by {growth:.0f} MB"  # runner RSS accounting varies; Boehm keeps swept pages on free lists
    assert pycr.pinned_count() == 0
    print(f"soak: 300 rounds, RSS growth {growth:.0f} MB, no leaked pins")

    # 19. Storable callables: owned references via PyRef finalizers
    import sys

    box = pycr.CallbackBox()
    try:
        box.invoke(1)
    except ValueError:
        pass
    else:
        raise SystemExit("FAIL: invoke with nothing attached did not raise")

    def triple(x):
        return x * 3

    base_refs = sys.getrefcount(triple)
    box.attach(triple)
    assert sys.getrefcount(triple) == base_refs + 1, "attach did not incref"
    assert box.invoke(7) == 21

    # the stored callable keeps working across Boehm collections
    pycr.stress(2)
    gc.collect()
    pycr.gc()
    assert box.invoke(6) == 18
    assert box.invocations == 2
    print("storable callables: attach, invoke, survive collections")

    # detach releases deterministically (Callable#release -> PyRef#release);
    # dropping without release would also decref, eventually, via the
    # Boehm finalizer (conservatism makes its timing unbounded)
    box.detach()
    assert sys.getrefcount(triple) == base_refs, "detach did not decref"
    try:
        box.invoke(1)
    except ValueError:
        pass
    print("detach decrefs deterministically; finalizer is the safety net")

    # the Callable conversion itself owns: dropping the Callable
    # (Python drops the argument tuple) decrefs back to baseline
    f = lambda x: x + 1
    base_f = sys.getrefcount(f)
    pycr.apply_func(f, 1)
    assert sys.getrefcount(f) == base_f, "transient Callable did not release"
    for _ in range(100):
        pycr.apply_func(f, 1)
    assert sys.getrefcount(f) == base_f, "transient Callables leaked a reference"
    print("100 transient Callable conversions, refcount back to baseline")

    # cyclic pattern: the stored callable's closure references Python
    # objects; no crash, and pins stay clean
    del box
    gc.collect()
    box2 = pycr.CallbackBox()
    payload = [1, 2, 3]

    def closing(x):
        return x + len(payload)

    box2.attach(closing)
    assert box2.invoke(10) == 13
    del box2, closing
    gc.collect()
    pycr.gc()
    pycr.gc()
    assert pycr.pinned_count() == 0
    print("cyclic-pattern cleanup: no crash, no leaked pins")

    thread_id = pycr.pyref_finalizer_same_thread()
    print(f"finalizer ran on bootstrap thread: {thread_id}")

    # 20. Scheduler on the importing thread (spike results, now
    #     regression-tested: notes/scheduler-spike.md)
    pycr.crystal_sleep(0.02)
    assert pycr.fiber_roundtrip(21) == 42
    assert pycr.spawn_many(500) == 500 * 499
    assert len(pycr.read_file("/etc/hostname")) > 0
    print("scheduler on importing thread: sleep, fibers, channels, fan-out, file IO")

    # fiber park under GIL release: spinner keeps running
    ticks = [0]
    stop = [False]

    def fiber_spinner():
        while not stop[0]:
            ticks[0] += 1

    fs = threading.Thread(target=fiber_spinner)
    fs.start()
    pycr.fiber_sleep_under_gil_release(0.15)
    stop[0] = True
    fs.join()
    assert ticks[0] > 100_000, "spinner starved during fiber park"
    print(f"fiber park under release_gil: spinner ran {ticks[0]} ticks")

    # foreign Python threads cannot enter the scheduler: clean
    # RuntimeError (this matches stock Crystal 1.21, where only the
    # main thread and EC pool threads have schedulers)
    foreign_errors = []

    def foreign():
        try:
            pycr.crystal_sleep(0.01)
        except RuntimeError as error:
            foreign_errors.append(str(error))

    ft = threading.Thread(target=foreign)
    ft.start()
    ft.join()
    assert foreign_errors and "cannot be nil" in foreign_errors[0], foreign_errors
    print("foreign threads: scheduler entry raises clean RuntimeError (stock Crystal behavior)")

    # 21. Iteration protocol: pyiter/pylen, laziness, concurrency
    wc = pycr.WordCounter()
    for word in ("alpha", "beta", "gamma"):
        wc.add(word)
    assert list(wc) == ["alpha", "beta", "gamma"]
    assert len(wc) == 3
    print("iteration: for-loop, list(), len() on a Crystal class")

    # independent concurrent iterators
    it1, it2 = iter(wc), iter(wc)
    assert (next(it1), next(it2), next(it1)) == ("alpha", "alpha", "beta")
    assert list(it1) == ["gamma"]
    print("concurrent iterations are independent")

    # laziness: Crystal side keeps accepting words mid-iteration
    it3 = iter(wc)
    next(it3)
    wc.add("delta")
    rest = list(it3)
    assert rest == ["beta", "gamma", "delta"], rest
    del it3
    print("iteration is lazy: words added mid-stream show up")

    # iterator survives Boehm collections mid-iteration (owner + state pinned)
    it4 = iter(wc)
    next(it4)
    pycr.stress(2)
    gc.collect()
    pycr.gc()
    assert list(it4) == ["beta", "gamma", "delta"]
    del it4
    gc.collect()
    pycr.gc()
    assert pycr.pinned_count() == 3  # wc + the still-live it1, it2
    del it1, it2
    gc.collect()
    pycr.gc()
    assert pycr.pinned_count() == 1  # only wc itself remains pinned
    del wc
    gc.collect()
    pycr.gc()
    assert wait_pins(), f'pins: {pycr.pinned_count()}'
    print("iterators survive GC cycles mid-iteration, then clean up")

    # exhausted iterators keep raising StopIteration; the iterator
    # keeps its source alive (by design), so delete it before checking
    # pin hygiene
    exhausted = iter(pycr.WordCounter())
    try:
        next(exhausted)
    except StopIteration:
        pass
    else:
        raise SystemExit("FAIL: empty iteration did not stop")
    del exhausted
    gc.collect()
    pycr.gc()
    assert wait_pins(), f'pins: {pycr.pinned_count()}'
    print("empty iteration stops cleanly; iterator + kept-alive source clean up")

    # annotation style: PyIter + PyLen on Greeter's log
    g = pycr.Greeter()
    g.greet("hey")
    g.greet("ho")
    assert list(g) == ["hey", "ho"]
    assert len(g) == 2
    del g
    gc.collect()
    pycr.gc()
    print("annotation style: PyIter + PyLen work")

    # 22. Subscript protocols: getitem/setitem/contains, both styles
    wc = pycr.WordCounter()
    for word in ("alpha", "beta", "gamma"):
        wc.add(word)
    assert wc[0] == "alpha"
    assert wc[-1] == "gamma"  # Crystal negative indexing carries over
    wc[1] = "BETA"
    assert list(wc) == ["alpha", "BETA", "gamma"]
    assert "BETA" in wc and "nope" not in wc

    for call, label in (
        (lambda: wc[99], "out-of-bounds getitem"),
        (lambda: wc.__setitem__(0, 3.5), "wrong value type"),
        (lambda: wc.__delitem__(0), "deletion"),
    ):
        try:
            call()
        except (IndexError, TypeError, NotImplementedError):
            pass
        else:
            raise SystemExit(f"FAIL: {label} did not raise")

    g = pycr.Greeter()
    g.greet("hey")
    g.greet("ho")
    assert g[0] == "hey"
    assert "hey" in g and "x" not in g
    assert len(g) == 2
    del wc, g
    gc.collect()
    pycr.gc()
    assert wait_pins(), f'pins: {pycr.pinned_count()}'
    print("subscripts: wc[i], wc[i]=, `in`, IndexError/TypeError/NotImplementedError, both styles")

    # 23. NamedTuple -> dict conversion; Callable keyword invocation
    stats = pycr.word_stats(["alpha", "beta", "alpha"])
    assert stats == {"count": 3, "unique": 2, "longest": "alpha"}
    empty = pycr.word_stats([])
    assert empty == {"count": 0, "unique": 0, "longest": ""}
    print("NamedTuple converts to dict (nested values convert too)")

    def styled(name, punct):
        return f"<{name}{punct}>"

    assert pycr.greet_with_kwargs(styled) == "<Crystal!>"
    try:
        pycr.greet_with_kwargs(lambda name: name)
    except TypeError:
        pass
    else:
        raise SystemExit("FAIL: wrong keyword signature did not raise")
    print("Callable keyword invocation works; arity mismatches raise TypeError")

    # 24. Slices: pygetitem + pylen compose into Python slice semantics
    wc = pycr.WordCounter()
    for word in ("alpha", "beta", "gamma", "delta", "epsilon"):
        wc.add(word)
    assert wc[0:2] == ["alpha", "beta"]
    assert wc[::2] == ["alpha", "gamma", "epsilon"]
    assert wc[::-1] == list(reversed(["alpha", "beta", "gamma", "delta", "epsilon"]))
    assert wc[1:100] == ["beta", "gamma", "delta", "epsilon"]  # clamped
    assert wc[-2:] == ["delta", "epsilon"]
    assert wc[2] == "gamma"  # plain indexing unaffected
    g = pycr.Greeter()
    g.greet("a"); g.greet("b"); g.greet("c")
    assert g[1:] == ["b", "c"]
    del wc, g
    gc.collect()
    pycr.gc()
    print("slices: positive/negative/step/clamped, both styles, plain indexing intact")

    # 26. Little bits: factories, getter-only attrs, compare/arithmetic,
    #     PyRef as a general storable reference
    factory_counter = pycr.counter_from(9)
    assert type(factory_counter) is pycr.Counter and factory_counter.value() == 9
    factory_wc = pycr.word_counter_from("fee fi fo")
    assert list(factory_wc) == ["fee", "fi", "fo"]
    print("factories: exposed instances returned from plain pyfunctions")

    assert factory_counter.doubled == 18
    factory_counter.increment(1)
    assert factory_counter.doubled == 20
    try:
        factory_counter.doubled = 1
    except NotImplementedError:
        pass
    else:
        raise SystemExit("FAIL: getter-only attribute accepted a write")
    print("getter-only attribute: reads derive, writes raise")

    left = pycr.word_counter_from("a b c")
    right = pycr.word_counter_from("a b")
    assert left > right and left >= right and right < left and right <= left
    assert left == pycr.word_counter_from("a b c")
    assert left != right
    assert list(left + right) == ["a", "b", "c", "a", "b"]
    assert (left == 3) is False  # incompatible: __eq__ fallback
    print("rich comparison + concatenation arithmetic; NotImplemented fallback")

    payload = {"key": [1, 2, 3]}
    pycr.remember(payload)
    assert pycr.recall() is payload
    payload["key"].append(4)
    assert pycr.recall()["key"] == [1, 2, 3, 4]
    del payload
    # release section instances: they hold pins until deleted
    del factory_counter, factory_wc, left, right
    gc.collect()
    pycr.gc()
    print("PyRef: arbitrary Python objects stored with identity preserved")

    # 27. Subclassing: Python classes extending exposed Crystal classes
    import sys

    class Loud(pycr.Counter):
        def __init__(self, count=0):
            super().__init__(count)
            self.starts = 0

        def increment(self, amount=1):
            self.starts += 1
            return super().increment(amount * 2)

    class LoudWC(pycr.WordCounter):
        pass

    loud = Loud(5)
    assert loud.value() == 5                    # tp_new ran with subtype
    assert loud.increment() == 7                # override: 5 + 1*2
    assert loud.starts == 1                     # Python-side state
    assert isinstance(loud, pycr.Counter)
    loud.count = 10                             # inherited pyattr write
    assert loud.count == 10
    assert repr(loud) == "Counter(count=10)"    # inherited pyrepr
    print("subclass: creation, super().__init__, overrides, extra state, inherited slots")

    # compare/arithmetic against subclass instances (isinstance unwrap)
    lw = LoudWC()
    lw.add("x"); lw.add("y")
    base = pycr.WordCounter(); base.add("z")
    assert lw > base and list(lw + base) == ["x", "y", "z"]
    del lw, base
    print("subclass instances work with inherited compare/arithmetic")

    del loud  # still alive from the first block; would hold a pin
    # type refcount must not drift (dealloc decrefs the type)
    before = sys.getrefcount(pycr.Counter)
    for _ in range(200):
        l = Loud(1); del l
    for _ in range(200):
        pycr.Counter(1)
    gc.collect(); pycr.gc()
    assert sys.getrefcount(pycr.Counter) == before, "type refcount drifted"
    assert pycr.pinned_count() == 0
    print("type refcount stable across 400 subclass/base cycles")

    # everything still works after all that churn
    assert pycr.hello() == "Hello from Crystal!"
    print("still healthy after stress + pin/unpin + threads")

    print("ALL TESTS PASSED")


if __name__ == "__main__":
    main()
