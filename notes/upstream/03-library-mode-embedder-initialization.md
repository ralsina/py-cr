# Upstream report 3 — no supported library-mode initialization; fibers unusable from host threads

Ready to file at: https://github.com/crystal-lang/crystal/issues/new
Labels: `kind:feature`, `topic:compiler`/`topic:docs` (runtime/embedding)

---

## Title

No documented, supported way to initialize a Crystal runtime inside a host process (dlopen'd `.so`), and host threads cannot run fibers

## Environment

- Crystal 1.21.0 (2026-07-23), `x86_64-pc-linux-gnu`
- Host: CPython 3.14 (regular and free-threaded builds), via a Python
  extension module — but any non-Crystal host that `dlopen`s
  Crystal-built shared objects is affected.

## Summary

Crystal supports `--cross-compile` object output and can be linked into
a shared library, but there is no documented contract for what the
**host** must run before calling into it, and no supported way for
host-created threads to use the concurrency runtime. Everything below
was reverse-engineered by debugging segfaults while building
[py-cr](https://github.com/ralsina/py-cr).

### 1. The runtime must be initialized manually — with undocumented calls

A normal program's `main` performs two initializations that `dlopen`
never does. A library must replicate both, and each omission produces a
distinct crash:

```crystal
# What a library-mode entry point must run (both are internal today):
Crystal.init_runtime                 # GC, Thread, Fiber, Once class vars
LibCrystalMain.__crystal_main(1, argv)  # global initializers
```

- **Without `Crystal.init_runtime`**: anything touching
  `Thread.current` (`@[ThreadLocal]`, `STDERR`, `Crystal::once`
  contention handling) segfaults in `Thread::LinkedList#push` on a NULL
  list.
- **Without `__crystal_main`**: constants with runtime initializers
  (file-scope `Regex` literals, `BakedFileSystem`, ...) are **eagerly**
  initialized by the compiler-generated `__crystal_main` — their call
  sites are a bare `mov slot; mov 0x18(%rax)` with no `__crystal_once`
  guard. If `__crystal_main` never ran, the slot is NULL and first use
  segfaults. `argv[0]` must be a real string (`PROGRAM_NAME`'s
  initializer dereferences it).

Nothing in the docs or the standard library offers a supported
entry point for this (contrast: `Py_InitializeFromConfig` in CPython,
`luaL_newstate` in Lua). A custom prelude replacing `crystal/once.cr`
is **not** an alternative — the eager constant path bypasses `once`
entirely.

### 2. Host-created threads cannot run fibers — even in ordinary Crystal programs

This one is stock Crystal 1.21, not library-mode-specific:

```crystal
# th.cr
thread = Thread.new do
  sleep 0.05
end
thread.join
puts "done"
```

```
$ crystal run th.cr
Unhandled exception: Thread#execution_context cannot be nil (NilAssertionError)
  from .../crystal/system/thread.cr:82:3 in 'execution_context'
  from .../fiber/execution_context.cr:166:5 in 'current'
```

In execution-context mode, fibers run only on the hijacked main thread
and on pool workers the EC created itself; `Thread#start` assigns no
execution context. For an embedder this means the scheduler (sleep,
`spawn`, IO through the event loop) is confined to the single thread
that initialized the library — from every other host thread it raises
the error above, and there is no supported API to adopt a foreign
thread into an execution context (the would-be entry points,
e.g. `hijack_current_thread`, are protected).

### 3. Free-threaded hosts make both gaps acute

With CPython's free-threaded builds (PEP 703, 3.13t/3.14t) any number
of host threads can enter Crystal code concurrently. Today a library
must serialize entry itself (a boundary mutex over the single-threaded
runtime) or attempt `-Dpreview_mt`, which is experimental and assumes
it owns thread creation. A supported library-mode initialization plus a
foreign-thread adoption story would let embedders do this properly.

## Asks

1. A **documented library-mode initialization API**: initialize the
   runtime and run global initializers without a `main` — even a thin,
   blessed wrapper around `Crystal.init_runtime` + the `__crystal_main`
   constant-initializer pass would remove the whole class of crashes.
2. **dlopen-safe (lazy) constant initialization**, or an explicit
   documented contract that the embedding host must call the init API
   exactly once before any code runs.
3. A **foreign-thread adoption API** (or, at minimum, docs stating that
   fibers are forbidden in `Thread.new` blocks and why).

## Evidence in py-cr

- Full write-up: [`notes/library-mode-initialization.md`](../library-mode-initialization.md)
  and [`notes/scheduler-spike.md`](../scheduler-spike.md)
- Working bootstrap in context:
  [`src/pycr.cr` (`bootstrap_module`)](https://github.com/ralsina/py-cr/blob/main/src/pycr.cr) —
  `Crystal.init_runtime` + `__crystal_main(1, argv)` at first import;
  the example module (tartrazine: 290 baked lexers, 388 themes)
  initializes in ~4 ms and the whole suite passes once these run.
