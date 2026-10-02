#!/bin/bash
# Compile BrcmIOVAFix.kext sans Xcode.
#   bash wifi/BrcmIOVAFix/build.sh            -> wifi/BrcmIOVAFix/build/BrcmIOVAFix.kext
#
# Outils : Command Line Tools locaux, sinon ceux du volume Sequoia (pas d'outils dev sur Tahoe).
# Dependances telechargees une fois dans build/deps : MacKernelSDK et le SDK de Lilu 1.7.1
# (meme version que le Lilu de l'EFI ; le SDK est dans le Lilu DEBUG, Contents/Resources).
set -euo pipefail
cd "$(dirname "$0")"

LILU_VERSION=1.7.1
NAME=BrcmIOVAFix
VERSION=1.0.0

for c in /Library/Developer/CommandLineTools "/Volumes/macos stable - Données/Library/Developer/CommandLineTools"; do
    [ -x "$c/usr/bin/clang++" ] && "$c/usr/bin/clang++" --version >/dev/null 2>&1 && { CLT=$c; break; }
done
[ -n "${CLT:-}" ] || { echo "ERREUR : pas de Command Line Tools utilisables" >&2; exit 1; }
CXX="$CLT/usr/bin/clang++"
CC="$CLT/usr/bin/clang"
CCKEXT=$(ls "$CLT"/usr/lib/clang/*/lib/darwin/libclang_rt.cc_kext.a | head -1)

DEPS=build/deps
mkdir -p "$DEPS"
if [ ! -d "$DEPS/MacKernelSDK/Headers" ]; then
    curl -fsSL https://codeload.github.com/acidanthera/MacKernelSDK/tar.gz/refs/heads/master | tar xz -C "$DEPS"
    mv "$DEPS/MacKernelSDK-master" "$DEPS/MacKernelSDK"
fi
if [ ! -d "$DEPS/Lilu.kext/Contents/Resources/Headers" ]; then
    curl -fsSL -o "$DEPS/lilu.zip" "https://github.com/acidanthera/Lilu/releases/download/$LILU_VERSION/Lilu-$LILU_VERSION-DEBUG.zip"
    unzip -oq "$DEPS/lilu.zip" -d "$DEPS"
fi
SDK="$DEPS/MacKernelSDK"
LILU="$DEPS/Lilu.kext/Contents/Resources"

COMMON=(-arch x86_64 -mmacosx-version-min=10.13 -mkernel -nostdlibinc
        -O2 -fno-builtin -fno-common -fno-asynchronous-unwind-tables
        -mmmx -msse -msse2 -msse3 -mssse3 -mfpmath=sse
        -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT
        "-DPRODUCT_NAME=$NAME" "-DMODULE_VERSION=$VERSION"
        -I "$SDK/Headers" -I "$LILU"
        -Wno-ossharedptr-misuse -Wno-unknown-warning-option -Wno-vla)

OBJ=build/obj
rm -rf "$OBJ" "build/$NAME.kext"
mkdir -p "$OBJ"
echo "== compilation ($CLT)"
"$CXX" "${COMMON[@]}" -std=c++14 -fapple-kext -fno-rtti -fno-exceptions -c kern_start.cpp -o "$OBJ/kern_start.o"
"$CXX" "${COMMON[@]}" -std=c++14 -fapple-kext -fno-rtti -fno-exceptions -c "$LILU/Library/plugin_start.cpp" -o "$OBJ/plugin_start.o"
"$CC"  "${COMMON[@]}" -std=c11 -c kmod_info.c -o "$OBJ/kmod_info.o"

echo "== edition de liens"
mkdir -p "build/$NAME.kext/Contents/MacOS"
"$CXX" -arch x86_64 -mmacosx-version-min=10.13 -nostdlib -Xlinker -kext -Xlinker -no_adhoc_codesign \
    "$OBJ/kern_start.o" "$OBJ/plugin_start.o" "$OBJ/kmod_info.o" \
    -L "$SDK/Library/x86_64" -lkmod "$CCKEXT" \
    -o "build/$NAME.kext/Contents/MacOS/$NAME"
cp Info.plist "build/$NAME.kext/Contents/Info.plist"
plutil -lint "build/$NAME.kext/Contents/Info.plist" >/dev/null
echo "Termine : $(pwd)/build/$NAME.kext"
