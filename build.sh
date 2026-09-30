#!/bin/bash
# Compile la couche corrigee et les programmes de test.
#   bash build.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

echo "== couche corrigee"
clang -O2 -x objective-c -Isrc -dynamiclib -framework Foundation -framework Metal \
  -install_name /System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/impostor.dylib \
  -o build/impostor.dylib src/impostor_tahoe.m

echo "== programmes de test"
for t in metaltest gputest stages clip color catt catt2 gotscan gotscan2 iosurf key; do
    [ -f "tests/$t.m" ] || continue
    clang -O2 -fobjc-arc -framework Metal -framework Foundation -framework IOSurface \
          -o "build/$t" "tests/$t.m" 2>/dev/null \
      || clang -O2 -fobjc-arc -framework Metal -framework Foundation -o "build/$t" "tests/$t.m"
    echo "   $t"
done
[ -f tests/sym.c ] && clang -O2 -o build/sym tests/sym.c && echo "   sym"

echo "== bibliotheques a injecter"
for d in both catt_hook impostor_inject sweep; do
    [ -f "tests/$d.m" ] || continue
    clang -O2 -x objective-c -Isrc -dynamiclib -framework Foundation -framework Metal \
          -o "build/$d.dylib" "tests/$d.m"
    echo "   $d.dylib"
done
echo
echo "Termine. Tout est dans build/."
echo "Exemple :  DYLD_INSERT_LIBRARIES=build/both.dylib FIX_FLAGS=1 FIX_CATT=1 build/metaltest"
