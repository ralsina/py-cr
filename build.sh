#!/bin/sh
# Builds pycr.so from src/pycr.cr.
#
# Why not just `crystal build --link-arg=-shared`?
#
# Crystal mangles some symbols with '@' (generic instantiations, proc
# closures). Every ELF linker available (lld, bfd, gold) misreads an '@'
# inside a symbol name as a symbol-version separator when that symbol
# would be exported from a shared object, so a straight -shared link
# fails. The workaround, which will become the framework's build step:
#
#   1. emit the whole program as a single object file
#   2. localize every '@'-mangled symbol with objcopy (one object means
#      no cross-object references can break)
#   3. link the shared object by hand, leaving the Py* symbols undefined
#      for the interpreter to resolve, as C extensions do on Linux
set -e
cd "$(dirname "$0")"

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

# --cross-compile stops after the object file (the later link step
# would fail on the intentionally-undefined Py* symbols); crystal
# emits pycr.o and prints its link suggestion, which we ignore.
# (Note: --cross-compile combined with --emit obj breaks the compiler
# on some setups - don't recombine them.)
FLAGS=""
if [ "${PYCR_FT:-0}" = "1" ]; then
  FLAGS="-Dpycr_ft"
fi
crystal build $FLAGS --cross-compile --no-debug -o "$BUILD/pycr" src/demo.cr

objcopy --wildcard --localize-symbol='*@*' "$BUILD/pycr.o" "$BUILD/pycr_loc.o"

CRYSTAL_LIB=$(crystal env CRYSTAL_LIBRARY_PATH)
# $ORIGIN rpath lets a packaged copy find a bundled libgc.so.1 next to
# it (packaging/); at the repo root the system libgc resolves as usual.
OUT="pycr.so"
if [ "${PYCR_FT:-0}" = "1" ]; then
  OUT="pycr_ft.so"
fi
cc -shared -Wl,-z,undefs -Wl,-rpath,'$ORIGIN' -o "$OUT" "$BUILD/pycr_loc.o" \
  -L"$CRYSTAL_LIB" -lgc -lpthread -ldl

echo "built $OUT"
