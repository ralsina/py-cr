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
