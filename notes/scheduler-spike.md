# Scheduler spike: Crystal's event loop under CPython (resolved)

Question: can Crystal's fiber scheduler / event loop run inside a
CPython process, and under what rules? This was the "pure-compute
only" limitation; the spike re-tested it after library-mode
initialization (`Crystal.init_runtime` + `__crystal_main`) was added,
because the original crash predated that fix.

## Results

Rung 1 — importing thread (re-baseline). ALL WORK now:
- `sleep` (the original crasher: `Thread.current` -> root `Fiber` ->
  `Thread::LinkedList#push` on a NULL list; `init_runtime`
  initializes those lists)
- `spawn` + `Channel` round-trip
- 1000-fiber fan-out and join
- file IO (`File.read`)

Rung 2 — GIL protocol:
- A fiber park wrapped in `Pycr.release_gil` sleeps with the GIL
  released: a Python spinner thread ran millions of ticks, the
  event-loop timer fired while released, re-acquisition clean.
- Control (park with GIL held): Python threads starve but nothing
  crashes - correct GIL semantics for a blocking call.

Rung 3 — foreign Python threads (threads other than the importer):
- Entering the scheduler raises a clean
  `RuntimeError: Thread#execution_context cannot be nil`, marshalled
  through the normal boundary. No crash.
- This is STOCK Crystal 1.21 behavior, not a library-mode artifact:
  a plain `crystal` program with `Thread.new { sleep 0.05 }` raises
  the same error. In execution-context mode, fibers only run on the
  hijacked main thread and on thread-pool workers the EC created
  itself; `Thread#start` assigns no execution context.
- Attempted workarounds, both dead ends:
  - Adopting a foreign thread into an EC would require calling
    `hijack_current_thread`-equivalent internals (protected) against
    pre-created schedulers, and a foreign thread is transient (it
    returns to Python), while a scheduler must persistently park.
  - Thread handoff (`Thread.new` a real Crystal worker, join from the
    foreign thread) dies on the stock-Crystal issue above: user-level
    `Thread.new` children have no EC in 1.21 either.

## The rules that fall out

1. Scheduler work is thread-affine to the importing thread. Funnel
   IO/spawn/sleep calls there from multithreaded Python (same pattern
   as Tkinter/asyncio thread affinity).
2. Any entry that parks a fiber wraps the park in `Pycr.release_gil`,
   so other Python threads keep running.
3. `Pycr.sleep_seconds` (raw nanosleep) remains the safe wait on
   foreign threads and for scheduler-free code paths.
4. Practical usage impact: single-threaded Python (the common case)
   has the full Crystal ecosystem available, IO included.
   Multithreaded Python gets compute from any thread, scheduler
   features from the importing thread.

## Upstream observations

- A user-level `Thread.new` child crashing with
  `Thread#execution_context cannot be nil` on first scheduler use is
  surprising 1.21 behavior (either `Thread#start` should enroll the
  child in the default EC, or the docs must say fibers are forbidden
  in `Thread.new` blocks). 5-line repro available.
- A supported foreign-thread adoption API would let py-cr offer
  scheduler access from any Python thread.

## Regression coverage

`test/test_pycr.py` section 20 pins all of this: the rung-1 probes,
the release_gil fiber park with a spinner, and the foreign-thread
clean error.

## Addendum: the bridge (experimental, one known deadlock)

`Pycr::Bridge.run` funnels foreign-thread scheduler work to a
dedicated Parallel context (capacity 1). Findings from building it:

- **Isolated contexts trap `spawn`**: `Isolated#enqueue_impl` only
  accepts its own main fiber, and `Isolated#spawn` routes to
  `@spawn_context` (the default EC). A job block calling bare `spawn`
  enqueues fibers onto the importing thread's context, whose scheduler
  never runs while Python owns that thread -> deadlock. First bridge
  design died here; the Parallel-context redesign fixed routing (bare
  `spawn` inside a job targets the bridge's own context).
- **GIL-contention deadlock (open)**: a foreign waiter blocked in the
  bridge wait (GIL released, pthread cond_wait) can deadlock when a
  CPU-bound Python thread hogs the GIL - the waiter's
  `PyEval_RestoreThread` after wake spins forever. Without concurrent
  CPU load, foreign bridge calls work (sleep, blocking IO). Suspect
  CPython 3.14 GIL handoff x PyEval_SaveThread/RestoreThread
  interleaving; needs upstream-grade investigation.
- Parallel.new/checkout from a foreign thread also appears
  nondeterministic; create ECs on the importing thread only (the
  framework does: eager start at import).

## Addendum 2: RESOLVED - AdoptingContext (custom execution context)

The execution context interface is pluggable (five abstract methods;
`Isolated` is ~100 lines) and the adoption setters are public. Key
insight: a single-fiber context never swaps - `sleep`/IO suspend and
resume entirely within the thread's own event loop, so the root fiber
(which runs Python's stack) needs no special treatment.

`Pycr::AdoptingContext.for_current_thread(name)`:
- `Thread.current` lazily creates the Thread + root fiber for the
  foreign thread (representing its current stack)
- sets `thread.execution_context` / `thread.scheduler` (public
  setters) to the new context, whose `@event_loop` is its own
- `sleep`/IO then suspend/resume through that loop on the foreign
  thread; `spawn` routes to the default EC (Isolated semantics)

`Bridge.run` = adopt once per thread + `release_gil { work }`. Works:
sleep, blocking IO, exceptions, sequential recycled-id threads, and
concurrent foreign callers.

## Gotchas found on the way

- Adoption state MUST live on the Thread object (check
  `thread.execution_context` in a begin/rescue - `getter!` raises on
  nil). A cache keyed by `pthread_self` breaks: glibc RECYCLES
  pthread_t values after thread exit, so a recycled thread skips
  adoption (NilAssertionError).
- Macro-heredoc batch edits failed silently repeatedly; use small
  verified edits.
