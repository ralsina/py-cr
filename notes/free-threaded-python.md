# Free-Threaded Python (PEP 703): Architecture & Migration Plan

This document outlines the architectural impact of CPython's free-threaded
mode (Python 3.13t and 3.14t with `--disable-gil`) on `py-cr`, the breakdown
points under the current design, and a phased roadmap to full support.

---

## 1. The Core Invariant Breakdown

`py-cr` currently maintains correctness and memory safety across two runtimes
because CPython's Global Interpreter Lock (GIL) acts as an implicit, global
mutual exclusion lock around Crystal execution:

```
CPython (GIL held) ──► [Boundary Entry] ──► [Single-Threaded Crystal Execution]
```

Even though foreign Python threads exist in `py-cr` tests (and release the GIL
during sleeps and IO), **no two threads execute Crystal code concurrently**.

In free-threaded Python (`python3.13t` / `python3.14t`):
1. **The GIL is removed**: Multiple Python threads enter `py_call` simultaneously
   across multiple CPU cores.
2. **Crystal runtime is already multi-threaded**: In Crystal 1.21+, multi-threading
   and the parallel execution context (`Fiber::ExecutionContext::Parallel`) are now
   the **default**. The compiler emits thread-safe allocations, atomic reference
   operations, and links multi-threaded Boehm GC. However, Crystal's standard
   collections (`Hash`, `Set`) are not thread-safe by design.
3. **Internal state is unguarded**: The pin registry (`Set(Void*)`), iterator
   states, eternal strings, and method caches are raw Crystal data structures.
   Previously guarded by CPython's GIL, concurrent mutations will now corrupt them.
4. **`safe_collect` assumption is violated**: `safe_collect` currently assumes
   no other thread is mid-call. Under free-threading, one thread may trigger a
   collection while other threads are in the middle of Crystal methods or
   allocations.
5. **Interpreter fallback**: Unless a module explicitly declares that it supports
   running without the GIL, CPython 3.13t re-enables the GIL process-wide and
   prints a warning.

---

## 2. Technical Vulnerability Inventory

### 2.1. Crystal Runtime Threading Status (Advantage)
- **Status**: In Crystal 1.21+, multi-threading is default (replacing the old
  `-Dpreview_mt` flag). Crystal's memory allocator, fiber scheduler, and runtime
  internals are already thread-safe.
- **Implication**: We do **not** have to fight the compiler or runtime to get
  thread-safe code generation. The work is strictly focused on synchronizing
  `py-cr`'s own data structures and coordinating with CPython's C-API.

### 2.2. Global Registries (`registry`, `iterator_states`, `kwlists`, `eternal_strings`)
- **Current**:
  ```crystal
  def self.registry : Set(Void*)
    @@registry ||= Set(Void*).new
  end
  ```
- **Impact**: Concurrent instance allocations or deallocations (`Pycr.pin` /
  `Pycr.unpin`) execute concurrent hash table inserts and deletes, causing race
  conditions and memory corruption.
- **Fix**: Protect with fine-grained mutexes or reader-writer locks (`pthread_rwlock_t`).

### 2.3. Boehm GC & Stop-the-World Under Concurrent Allocation
- **Current**: Automatic collection is disabled (`GC_disable`); collections occur
  exclusively via `safe_collect` guarded by a pthread mutex and allocation debt
  triggers.
- **Impact**: In free-threading, Thread A may call `safe_collect` (`GC.collect`)
  while Thread B is allocating memory or running a Crystal method. Boehm sends
  signals (`SIGPWR`/`SIGXCPU`) to suspend Thread B.
- **Requirement**: Thread B must be in an unsuspendable-safe state (not holding
  internal locks that the collector or finalizers need). Hot paths must never take
  libgc's internal locks (e.g., `GC_get_heap_size`).

### 2.4. `PyRef` Indirection Cell Race
- **Current**:
  ```crystal
  def release : Nil
    object = @object
    return if object.null?
    @object = Pointer(Void).null.as(Py::Object)
    @cell.value = Pointer(Void).null
    Py.Py_DecRef(object)
  end
  ```
- **Impact**: If two threads call `release` or `pyref_finalize` on the same `PyRef`
  simultaneously, a data race on `@cell.value` and `@object` can cause a double
  `Py_DecRef`.
- **Fix**: Use atomic swap/CAS on `@cell.value`.

### 2.5. Borrowed Python Collections
- **Current**: `from_python(obj, Array(T))` iterates through `PyList_GetItem`.
- **Impact**: In free-threaded Python, another thread may mutate the list while
  Crystal is converting it.
- **Fix**: Wrap borrowed collection conversions in CPython 3.13 critical sections
  (`Py_BEGIN_CRITICAL_SECTION`).

---

## 3. Phased Roadmap

### Phase 1: Boundary Mutex & Opt-In (Fast, 100% Safe)

**Goal**: Support `python3.13t` immediately without destabilizing the single-threaded
Crystal runtime or requiring `-Dpreview_mt`.

```
Python Thread 1 (Core 1) ──► [Python Code] ──► [Crystal Mutex (acquired)] ──► [Crystal Execution]
Python Thread 2 (Core 2) ──► [Python Code] ──► [Crystal Mutex (queued)]
Python Thread 3 (Core 3) ──► [Python Code] ──► (Runs freely in Python runtime)
```

1. **Declare GIL Not Used**:
   At `bootstrap_module`, invoke `PyUnstable_Module_SetGIL`:
   ```crystal
   lib Py
     $mod_gil_not_used = 0_i64 : Void* # Py_MOD_GIL_NOT_USED is (void*)0
   end

   set_gil = LibC.dlsym(Pointer(Void).null, "PyUnstable_Module_SetGIL")
   unless set_gil.null?
     fn = Proc(Py::Object, Void*, Int32).new(set_gil, Pointer(Void).null)
     fn.call(module_object, pointerof(Py.mod_gil_not_used))
   end
   ```
2. **Boundary Recursive Mutex**:
   Wrap `Pycr.py_call` in a reentrant pthread mutex (`PTHREAD_MUTEX_RECURSIVE`).
   Reentrant is required because Python callbacks (`Callable`) may call back into
   Crystal.
3. **Release Boundary Mutex in `release_gil`**:
   When Crystal yields the GIL during long compute or IO (`Pycr.release_gil`), drop
   the boundary mutex so other Python threads can enter Crystal.

**Result**: CPython runs free-threaded without enabling the GIL; Python code
scales across cores; Crystal execution is serialized and safely protected.

---

### Phase 2: State Hardening & Atomic References

**Goal**: Make all framework-level bookkeeping thread-safe.

1. **Synchronize Registries**:
   ```crystal
   module Pycr
     @@registry_mutex = Thread::Mutex.new

     def self.pin(pointer : Void*) : Nil
       @@registry_mutex.synchronize { registry << pointer }
     end

     def self.unpin(pointer : Void*) : Nil
       @@registry_mutex.synchronize { registry.delete(pointer) }
     end
   end
   ```
2. **Atomic Swap in `PyRef`**:
   ```crystal
   def release : Nil
     raw_cell = @cell.as(Atomic(Pointer(Void)))
     old_ptr = raw_cell.swap(Pointer(Void).null)
     unless old_ptr.null?
       Py.Py_DecRef(old_ptr.as(Py::Object))
     end
   end
   ```
3. **Atomic Keyword Lists & Eternal Strings**:
   Protect `@@kwlists` and `@@eternal_strings` using a read-write lock or pre-bake
   at module initialization.

---

### Phase 3: Full Parallel Execution (Unlocking Concurrent Multi-Core Compute)

**Goal**: True parallel, multi-core Crystal compute directly from Python threads without the Phase 1 boundary lock.

Since Crystal 1.21+ already compiles with multi-threading and the `Parallel` execution context by default, the runtime foundation is already in place. Unlocking full parallelism requires:

1. **Retire the Boundary Mutex**:
   Once registries (Phase 2) are synchronized, remove the boundary mutex from `py_call`, allowing concurrent execution across CPU cores.
2. **Multi-Thread Boehm GC Verification**:
   - Verify `libgc.so.1` is compiled with multi-thread support (`-DGC_THREADS`).
   - Every entering thread registers via `GC_register_my_thread`.
   - Maintain serialized collection via `safe_collect` so collections occur only
     at controlled synchronization points.
3. **AdoptingContext Under Concurrency**:
   - Each OS thread adopts independently into its own `AdoptingContext` and event loop.
   - Fiber channels shared across threads must use thread-safe channel semantics.
4. **Critical Sections for Borrowed Objects**:
   Bracket borrowed object access using CPython's critical section API:
   ```crystal
   lib Py
     fun PyCriticalSection_Begin(cs : Void*, obj : Object)
     fun PyCriticalSection_End(cs : Void*)
   end
   ```

---

## 4. Verification & Testing Matrix

To certify free-threading compatibility:

1. **CI Runner**: Add a job with `python-version: "3.13t"` in `.github/workflows/ci.yml`.
2. **GIL Status Check**:
   ```python
   import sys
   assert not sys._is_gil_enabled()
   ```
3. **Parallel Stress Gauntlet**:
   - 8–16 Python threads hammering `WordCounter`, `Counter`, and compute functions
     simultaneously.
   - Concurrent allocation debt collections racing against active worker threads.
   - Rapid thread creation and exit to stress pthread TLS key destructors and
     `GC_unregister_my_thread`.
