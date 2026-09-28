# Boehm GC vs CPython threads: the full story (resolved)

How py-cr makes Boehm's stop-the-world collector coexist with CPython
3.14 threads. Every piece below is load-bearing; removing any one of
them reintroduces a crash.

## 1. Register every entering thread

libgc's pthread interception cannot see threads CPython created before
our .so was dlopened, so allocating/collecting from a Python thread
aborts with "Collecting from unknown thread". Every thread registers
itself on first boundary entry (`GC_allow_register_threads` once, then
`GC_register_my_thread`), tracked with raw pthread TLS.

- Crystal's `@[ThreadLocal]` and class-var *initializers* are unusable
  here: the former routes through `Thread.current` (the scheduler never
  initializes in library mode — it segfaults on foreign threads), the
  latter only run in the dead executable code path, so nil reads as
  truthy. Nilable lazy class vars and pthread TLS instead.

## 2. Unregister at thread exit

CPython threads die without notice. A stale registration makes the next
stop-the-world try to suspend a dead pthread, which aborts with
"Signals delivery fails constantly". The pthread key destructor calls
`GC_unregister_my_thread` when the thread exits. This was the last
missing piece: even collections from otherwise-idle threads aborted
once any extension-using thread had finished.

## 3. Collect only at framework-chosen moments

With automatic collection disabled at bootstrap (`GC_disable`),
collections happen only through `safe_collect`: serialized by a raw
pthread mutex (Crystal's `Mutex` parks waiters via `Thread.current` —
foreign-thread crash again) and always called from GIL-held boundary
points, so no other thread can be mid-extension-call. Boehm must be
re-enabled around the actual `GC.collect`: with GC disabled,
`GC_gcollect` does not reclaim.

Allocation debt is tracked with a plain atomic fed from the conversion
layer — never `GC_get_heap_size` on the hot path: it takes libgc's
internal lock, and a thread parked there is an unsuspendable target for
a concurrent stop-the-world.

## Result

The full melee passes repeatedly: concurrent explicit collectors,
allocator threads triggering debt collections, a Python spinner, and a
GIL-released napper, all at once (`test/test_pycr.py`, section 15).

## Remaining sharp edges

- `Pycr.heap_size` (GC_get_heap_size) must not be called from one
  thread while another collects; the demo's `heap()` is for
  single-threaded introspection.
- Crystal's scheduler (sleep, fibers, IO) still cannot start under
  CPython: use `Pycr.sleep_seconds`.

## Alternative collectors

[gcry](https://forum.crystal-lang.org/t/gcry-a-garbage-collector-written-in-pure-crystal/9072)
(a conservative, non-moving, stop-the-world mark-sweep collector in
~9k lines of pure Crystal, selected via `-Dgc_none` + a shard require)
is the strategic escape hatch if Boehm's suspend semantics ever bite
again: being pure Crystal, its stop-the-world could be adapted to a
CPython-aware mode — collect only while the GIL is held, never suspend
foreign threads (sound under py-cr's ownership rules: everything
cross-call goes through the rooted pin registry, and release_gil
sections hold no Crystal references). Today it is not a drop-in fix:
same collector family with signal-based suspension, single-parallelism
configuration, and production segfaults reported against it; Boehm
with the policy above is the stronger choice.
