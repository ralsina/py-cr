# Library-mode initialization: what a Crystal .so must run at PyInit

Found while building examples/tartrazine; the demo module masked all of
it because it uses only string-literal constants and truthy defaults.

A normal Crystal program's `main` runs three things that dlopen never
does, and each omission produces a distinct crash:

1. `Crystal.init_runtime` — initializes the Thread/Fiber/Once class
   vars. Without it, `Thread.current` (reached through `STDERR`,
   `@[ThreadLocal]`, or `Crystal::once` contention handling) segfaults
   in `Thread::LinkedList#push` on a NULL list.

2. `__crystal_main(argc, argv)` — the compiler-generated initializer
   for constants with runtime initializers. These are NOT lazily
   guarded: the call site is `mov slot; mov 0x18(%rax)` with no
   `__crystal_once` — if `__crystal_main` never ran, the slot is NULL
   and the first read of any file-scope Regex literal, baked file
   system, or similar constant segfaults. argv[0] must be a real
   string: `PROGRAM_NAME`'s initializer dereferences it.

   A custom prelude replacing crystal/once.cr was tried first and is
   NOT needed (and not sufficient: the eager path bypasses once
   entirely).

3. Macro default-value truthiness (framework bug this exposed):
   `{% if arg.default_value %}` is falsy for defaults of literal
   `false`/`nil`, silently dropping the `|` from the ParseTuple format
   and converting a NULL optional. Nil-check instead:
   `{% if !arg.default_value.nil? %}`.

## Envelope after these fixes

Real-library constants initialize at import (tartrazine's 290 baked
lexers, 388 themes), `import` takes ~4 ms, and the whole example test
suite passes. Remaining known hard limit: Crystal's scheduler (sleep,
fibers, IO through the event loop) still cannot run — raw nanosleep
and pure-compute code only.

## Upstream-worthy

The /tmp-derived repro: a .so exporting a fun that reads a file-scope
Regex constant crashes unless the host calls `Crystal.init_runtime`
and `__crystal_main(argc, argv)` first — nothing on the Crystal side
documents a supported way to do this from a library. An official
library-mode entry point (or dlopen-safe lazy init) would remove the
whole class.
