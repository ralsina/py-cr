# Upstream report 2 — ELF linkers reject Crystal's `@`-mangled symbols in shared libraries

Filed as: https://github.com/crystal-lang/crystal/issues/17505

---

## Title

Symbol names containing `@` cannot be linked into ELF shared objects — lld: `has undefined version`, GNU ld: `version node not found`

## Environment

- Crystal 1.21.0 (2026-07-23), LLVM 22.1.8 / lld 22, GNU ld (bfd) 2.44
- Arch Linux (reproduced), ubuntu-22.04 GitHub runner (reproduced)

## Summary

Crystal's name mangling embeds `@` in symbol names, e.g.:

```
*StaticArray(UInt64, 2)@StaticArray(T, N)#to_slice:Slice(UInt64)
```

ELF linkers treat `@` in a symbol name as the **symbol-version
separator** (`sym@version`). When a Crystal program is linked as a
shared object through Crystal's own link step (multi-object codegen),
every cross-object reference to such a symbol fails to match its
definition, and the link aborts. `crystal build --link-flags=-shared`
on any nontrivial program produces hundreds of errors like:

```
ld.lld: error: S-taticA-rray40U-I-nt644432241.o0.o: symbol *StaticArray(UInt64, 2)@StaticArray(T, N)#to_slice:Slice(UInt64) has undefined version StaticArray(T, N)#to_slice:Slice(UInt64)
ld.lld: error: P-ointer40U-I-nt841.o0.o: symbol *Pointer(UInt8)@Comparable(T)#<<Pointer(UInt8)>:Bool has undefined version Comparable(T)#<<Pointer(UInt8)>:Bool
```

GNU ld fails the same way with its own wording:

```
/usr/bin/ld.bfd: libdemo.so: version node not found for symbol *Pointer(Crystal::Once::Operation)@Object#!=<Pointer(Crystal::Once::Operation)>:Bool
/usr/bin/ld.bfd: failed to set dynamic section sizes: bad value
```

## Reproduction

Any program with generic instantiations:

```
$ crystal build --link-flags=-shared --no-debug -o libdemo.so src/demo.cr
ld.lld: error: ... has undefined version ...        # lld
/usr/bin/ld.bfd: ... version node not found ...     # with -fuse-ld=bfd
```

## Why single-object links work

With `--cross-compile` (stop after emitting one object file) the same
symbols are `STB_LOCAL` **within that single object**: definitions and
references resolve statically before any dynamic symbol table is built,
and locals never enter `.dynsym`. The bug only fires when definitions
and references live in different objects (Crystal's multi-object
codegen) and the linker must match them across objects — exactly the
shared-library case, where `@` suddenly means "version".

## Workaround (shipped in py-cr)

`build.sh` links the shared object by hand:

1. Emit the whole program as one object:
   `crystal build --cross-compile --no-debug -o build/pycr src/demo.cr`
2. Localize every `@`-mangled symbol (safe: one object, so no
   cross-object references can break):
   `objcopy --wildcard --localize-symbol='*@*' build/pycr.o pycr_loc.o`
3. Link manually, leaving the host's symbols undefined for the loading
   process (as C extensions do):
   `cc -shared -Wl,-z,undefs -o pycr.so pycr_loc.o -lgc -lpthread -ldl`

This works on lld, bfd and gold — but it is fragile and costs the
multi-object codegen.

## Suggested fixes

Any of these would remove the workaround:

- Avoid `@` in mangled symbol names (e.g. `__`, `$`, or `.AT.`), or
- make the mangling character configurable, or
- document the constraint and provide a supported "shared library"
  link mode that localizes these symbols automatically.

---

## Companion bug on the same build path (filed separately)

Filed as: https://github.com/crystal-lang/crystal/issues/17506

`--cross-compile` combined with `--emit obj` crashes the compiler when
the per-program cache directory is cold (it worked on warm caches,
which masked it for a while):

```
$ echo 'puts "hello"' > hello.cr
$ crystal build --cross-compile --emit obj --no-debug -o hello hello.cr
Error opening file with mode 'r': '/home/me/.cache/crystal/tmp-emitrepro-hello.cr/_main.o0.o': No such file or directory (File::NotFoundError)
  from .../file.cr:176:20 in 'cp'
  from .../compiler/crystal/compiler.cr:1090:11 in 'emit'
  from .../compiler/crystal/compiler.cr:837:5 in 'codegen'
Error: you've found a bug in the Crystal compiler. Please open an issue, including source code that will allow us to reproduce the bug: https://github.com/crystal-lang/crystal/issues
```

With `--cross-compile --emit obj` the compiler tries to `File.cp` the
main module's object (`_main.o0.o`) out of the cache, but never wrote
it there — cold cache means the file does not exist and the copy
raises. A second `crystal build` run succeeds because some other
per-module objects were written before the crash. Observed identically
on Arch Linux and ubuntu-22.04 CI (Crystal 1.21.0, both jobs of
[py-cr run 36471352828](https://github.com/ralsina/py-cr/actions/runs/36471352828)).
