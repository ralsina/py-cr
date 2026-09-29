# Upstream report 1 — Crystal compiler crash

Ready to file at: https://github.com/crystal-lang/crystal/issues/new
Labels: `kind:bug`, `topic:compiler` (semantic phase)

---

## Title

Compiler crash: `Cast from Nil to Crystal::ProcInstanceType failed (bindings.cr:596)` — a NoReturn-typed argument to an overloaded method, inside a typed, closured block

## Environment

- Crystal 1.21.0 (2026-07-23), LLVM 22.1.8
- `x86_64-pc-linux-gnu` (Arch Linux, gcc 15)

## Summary

Passing a call whose type is NoReturn (a def that only raises) as the
argument of an **overloaded** method, from inside a **typed** block that
closures (`&block : -> T`), crashes the compiler in the semantic phase:

```
Cast from Nil to Crystal::ProcInstanceType failed, at /build/crystal/src/crystal-1.21.0/src/compiler/crystal/semantic/bindings.cr:596:7 (TypeCastError)
```

Each ingredient alone compiles fine; only the combination crashes.

## Reproducer

```crystal
# repro.cr
alias Obj = Pointer(Void)

module Conv
  def self.to_python(value : Nil) : Obj
    Obj.null
  end

  def self.to_python(value : String) : Obj
    Obj.null
  end
end

module Boundary
  def self.py_call(&block : -> Obj) : Obj
    block.call
  rescue Exception
    Obj.null
  end
end

def boom : Nil
  raise "boom"
end

def entry : Obj
  Boundary.py_call do
    Conv.to_python(boom)
  end
end

puts entry
```

```
$ crystal build repro.cr; echo "exit code: $?"
Cast from Nil to Crystal::ProcInstanceType failed, at .../crystal/semantic/bindings.cr:596:7 (TypeCastError)
  from crystal in '??'
  from crystal in '??'
  from crystal in '??'
  ... 18 more backtrace frames from the compiler binary ...
  from /usr/lib/libc.so.6 in '__libc_start_main'
  from crystal in '_start'
  from ???
Error: you've found a bug in the Crystal compiler. Please open an issue, including source code that will allow us to reproduce the bug: https://github.com/crystal-lang/crystal/issues
exit code: 1
```

This is a crash, not a diagnostic: the exception is raised **inside the
compiler** (its own `TypeCastError`, in the semantic phase), so the
output carries no source location or caret for the user's program —
just the compiler's internal backtrace and its own "you've found a bug"
crash-handler message. Compare a normal type error, which points at the
offending line (`In repro.cr:20:5 ... Error: ...`). The compiler process
aborts with exit code 1 and produces no binary.

## Ingredients (removing any one fixes it)

1. **Overloaded callee** — `Conv.to_python` has two overloads. A
   single-arity `to_python(value : Nil)` compiles.
2. **NoReturn-typed argument** — `boom` is a raise-only def, so the call
   type is NoReturn. Passing `nil` instead compiles.
3. **Typed block parameter** — `&block : -> Obj` makes the block convert
   to a `Proc`. An untyped `&block` with plain `yield` compiles.

## Workaround (shipped in py-cr)

Use an untyped block and `yield` instead of a typed `&block : -> T`, so
the block is never converted to a Proc object:

```crystal
def py_call : Obj
  yield
rescue Exception
  Obj.null
end
```

## Context

Found while building [py-cr](https://github.com/ralsina/py-cr), a
framework for writing Python extension modules in Crystal: every
Python-facing callback returns `Pointer(Void)`, error handling is
raise-based, and boundary thunks wrap user code in a typed block — the
first module that raised through the boundary hit this at compile time.
The minimal reproducer above is
[`notes/crystal-1.21-no-return-proc-bug.cr`](../crystal-1.21-no-return-proc-bug.cr)
in the py-cr repo.
