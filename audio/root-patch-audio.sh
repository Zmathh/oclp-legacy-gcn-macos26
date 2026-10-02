#!/bin/bash
# Audio HDA Intel sur macOS 26 : Tahoe ne contient plus AppleHDA.kext.
#
#   sudo bash audio/root-patch-audio.sh /chemin/AppleHDA.kext   installe, kernel collections, snapshot
#   sudo bash audio/root-patch-audio.sh --revert                retire,   kernel collections, snapshot
#
# Source : AppleHDA.kext d'un macOS 15 installe, par exemple
#   "/Volumes/macos stable/System/Library/Extensions/AppleHDA.kext" (600.2, 15.8).
# Ses dependances existent toutes dans macOS 26.0 et ses 1013 imports s'y resolvent (verifie).
# Le KDK doit deja etre fusionne dans le volume systeme (c'est le cas apres le patch GPU d'OCLP).
#
# Avant kmutil, les kernel collections en place sont copiees dans
#   /Users/Shared/rescue-tahoe-kc/<snapshot demarre>/
# Si kmutil echoue, elles sont remises et rien n'est active. Si macOS 26 ne demarre plus apres,
# rescue/rescue-tahoe.sh audio les remet depuis Sequoia.
set -euo pipefail

MNT=/System/Volumes/Update/mnt1
SHIM=System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/impostor.dylib
KC=System/Library/KernelCollections
HDA=System/Library/Extensions/AppleHDA.kext
KCSAVE=/Users/Shared/rescue-tahoe-kc

die() { echo "ERREUR : $*" >&2; exit 1; }

MODE=install
SRC=""
case "${1:-}" in
    --revert) MODE=revert ;;
    "")       die "usage : root-patch-audio.sh /chemin/AppleHDA.kext | --revert" ;;
    *)        SRC=$1 ;;
esac

[ "$(id -u)" = 0 ] || die "lancer avec sudo"
[ "$(uname -r | cut -d. -f1)" = 25 ] || die "prevu pour macOS 26 (Darwin 25) uniquement"
reg=$(ioreg -r -n HDEF -d 1 2>/dev/null)
grep -q "HDEF" <<<"$reg" || die "pas de controleur audio HDA (HDEF)"

if [ "$MODE" = install ]; then
    [ -f "$SRC/Contents/Info.plist" ] && [ -f "$SRC/Contents/MacOS/AppleHDA" ] || die "$SRC n'est pas un AppleHDA.kext"
    id=$(plutil -extract CFBundleIdentifier raw "$SRC/Contents/Info.plist")
    [ "$id" = com.apple.driver.AppleHDA ] || die "$SRC : identifiant $id"
    echo "source : $SRC ($(plutil -extract CFBundleVersion raw "$SRC/Contents/Info.plist"))"
fi

# --- volume systeme vivant (le / demarre est un snapshot en lecture seule)
info=$(diskutil info -plist /)
dev=$(plutil -extract DeviceIdentifier raw - <<<"$info")
snap=$(diskutil info / | awk -F': *' '/APFS Snapshot Name/ {print $2}')
if [ "$(plutil -extract APFSSnapshot raw - <<<"$info" 2>/dev/null || echo false)" = true ]; then
    dev=${dev%s*}
fi
if [ ! -f "$MNT/System/Library/CoreServices/SystemVersion.plist" ]; then
    mkdir -p "$MNT"
    mount -o nobrowse -t apfs "/dev/$dev" "$MNT" || die "montage de /dev/$dev impossible"
fi
echo "volume systeme : /dev/$dev monte sur $MNT (snapshot demarre : ${snap:-?})"

live_build=$(plutil -extract ProductBuildVersion raw "$MNT/System/Library/CoreServices/SystemVersion.plist")
[ "$live_build" = "$(sw_vers -buildVersion)" ] \
    || die "le volume vivant est en $live_build, le systeme demarre en $(sw_vers -buildVersion)"
if [ -f "/$SHIM" ]; then
    cmp -s "/$SHIM" "$MNT/$SHIM" \
        || die "impostor.dylib du volume vivant differe de celui qui tourne : le snapshot perdrait la couche GPU"
fi
ls -d "$MNT"/System/Library/Extensions/*.dSYM >/dev/null 2>&1 \
    || die "aucun .dSYM dans le volume systeme : KDK non fusionne, kmutil ne pourra pas reconstruire"
[ "$MODE" = revert ] && [ ! -d "$MNT/$HDA" ] && die "pas d'AppleHDA.kext sur le volume systeme : rien a retirer"

# --- sauvegarde des kernel collections en place
save="$KCSAVE/${snap:-sans-nom}"
if [ ! -f "$save/SystemKernelExtensions.kc" ]; then
    mkdir -p "$save"
    cp -p "$MNT/$KC"/*.kc "$MNT/$KC"/*.elides "$save/"
    echo "$snap $(date '+%Y-%m-%d %H:%M') avant $MODE AppleHDA" > "$save/README.txt"
fi
echo "kernel collections sauvegardees dans $save"

old_kext=""
if [ -d "$MNT/$HDA" ]; then
    old_kext=$(mktemp -d /private/var/tmp/applehda-old.XXXXXX)
    ditto "$MNT/$HDA" "$old_kext/AppleHDA.kext"
fi

undo() {
    echo "== retour a l'etat precedent"
    rm -rf "${MNT:?}/${HDA:?}"
    [ -n "$old_kext" ] && ditto "$old_kext/AppleHDA.kext" "$MNT/$HDA"
    cp -p "$save"/*.kc "$save"/*.elides "$MNT/$KC/"
}

if [ "$MODE" = install ]; then
    echo "== installation d'AppleHDA.kext"
    rm -rf "${MNT:?}/${HDA:?}"
    ditto "$SRC" "$MNT/$HDA"
    chown -R root:wheel "$MNT/$HDA"
    chmod -R go-w "$MNT/$HDA"
else
    echo "== retrait d'AppleHDA.kext"
    rm -rf "${MNT:?}/${HDA:?}"
fi

echo "== kernel collections (kmutil, quelques minutes)"
if ! kmutil create --allow-missing-kdk --volume-root "$MNT" --update-all --variant-suffix release; then
    undo
    die "kmutil a echoue : kernel collections et AppleHDA remis comme avant, aucun snapshot cree"
fi

echo "== nouveau snapshot"
if ! bless --folder "$MNT/System/Library/CoreServices" --bootefi --create-snapshot; then
    undo
    die "bless a echoue : etat precedent remis, aucun snapshot cree"
fi
diskutil unmount "$MNT" >/dev/null 2>&1 || true
[ -n "$old_kext" ] && rm -rf "${old_kext:?}"

echo
echo "Termine. Redemarrer, puis verifier : system_profiler SPAudioDataType"
echo "Secours si macOS 26 ne demarre plus : depuis Sequoia, rescue-tahoe.sh audio"
