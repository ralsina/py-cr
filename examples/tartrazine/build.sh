#!/bin/sh
# Builds tartrazine.so from examples/tartrazine/src/tartrazine_py.cr.
# Same objcopy workaround as the framework's build.sh (see that file
# for why a plain -shared link cannot work).

set -e
cd "$(dirname "$0")"

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

crystal build --release --cross-compile --no-debug -o "$BUILD/tt" src/tartrazine_py.cr

objcopy --wildcard --localize-symbol='*@*' "$BUILD/tt.o" "$BUILD/tt_loc.o"

CRYSTAL_LIB=$(crystal env CRYSTAL_LIBRARY_PATH)
cc -shared -Wl,-z,undefs -o tartrazine.so "$BUILD/tt_loc.o" \
  -L"$CRYSTAL_LIB" -lgc -lpthread -ldl -lxml2 -lpcre2-8 -lyaml

echo "built tartrazine.so ($(du -h tartrazine.so | cut -f1))"
