#!/bin/sh
# Builds tartrazine.so from examples/tartrazine/src/tartrazine_py.cr.
# Same objcopy workaround as the framework's build.sh (see that file
# for why a plain -shared link cannot work).

set -e
cd "$(dirname "$0")"

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

if ! crystal build --emit obj --no-debug -o "$BUILD/tt.o" src/tartrazine_py.cr 2>"$BUILD/compile.log"; then
  if [ ! -f "$BUILD/tt.o" ]; then
    cat "$BUILD/compile.log" >&2
    exit 1
  fi
fi

objcopy --wildcard --localize-symbol='*@*' "$BUILD/tt.o" "$BUILD/tt_loc.o"

CRYSTAL_LIB=$(crystal env CRYSTAL_LIBRARY_PATH)
cc -shared -Wl,-z,undefs -o tartrazine.so "$BUILD/tt_loc.o" \
  -L"$CRYSTAL_LIB" -lgc -lpthread -ldl -lxml2 -lpcre2-8 -lyaml

echo "built tartrazine.so ($(du -h tartrazine.so | cut -f1))"
