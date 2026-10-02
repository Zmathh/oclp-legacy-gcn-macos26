#!/bin/bash
# Pile Wi-Fi heritee (Ventura) d'OCLP dans le config.plist d'OpenCore, pour macOS 26.
#
#   bash wifi/efi-wifi.sh [config.plist]            diagnostic, ne modifie rien
#   bash wifi/efi-wifi.sh --apply [config.plist]    active les 4 entrees aussi sur Darwin 25,
#                                                   ajoute BCMWLAN-Block.kext et BrcmIOVAFix.kext
#   bash wifi/efi-wifi.sh --revert [config.plist]   remet MaxKernel 24.99.99 (etat d'origine)
#                                                   et desactive les deux kexts du depot
#
# Sans chemin, cherche /Volumes/*/EFI/OC/config.plist (monter l'EFI avant :
#   sudo diskutil mount 408679D7-722D-47FF-86E8-D935A798AEC6 ; par UUID, car diskN change
#   d un demarrage a l autre : disk0s1 a deja designe l EFI de secours).
# Avant --apply, une copie est faite dans config.plist.pre-wifi (une seule fois).
set -euo pipefail

PB=/usr/libexec/PlistBuddy
MODE=check
case "${1:-}" in
    --apply)  MODE=apply;  shift ;;
    --revert) MODE=revert; shift ;;
esac

CFG="${1:-}"
if [ -z "$CFG" ]; then
    shopt -s nullglob
    found=(/Volumes/*/EFI/OC/config.plist)
    if [ ${#found[@]} -ne 1 ]; then
        echo "Indiquer le config.plist : ${#found[@]} EFI trouve(s) dans /Volumes." >&2
        exit 1
    fi
    CFG="${found[0]}"
fi
[ -f "$CFG" ] || { echo "Introuvable : $CFG" >&2; exit 1; }
KEXTS="$(dirname "$CFG")/Kexts"
echo "config : $CFG"

# Les trois kexts doivent etre dans cet ordre : chacun depend du precedent.
WANTED=(
    "IOSkywalkFamily.kext"
    "IO80211FamilyLegacy.kext"
    "IO80211FamilyLegacy.kext/Contents/PlugIns/AirPortBrcmNIC.kext"
)

get() { $PB -c "Print :$1" "$CFG" 2>/dev/null || true; }

add_index() {
    local i=0 b
    while b=$($PB -c "Print :Kernel:Add:$i:BundlePath" "$CFG" 2>/dev/null); do
        [ "$b" = "$1" ] && { echo "$i"; return; }
        i=$((i + 1))
    done
    echo ""
}

add_count() {
    local i=0
    while $PB -c "Print :Kernel:Add:$i" "$CFG" >/dev/null 2>&1; do i=$((i + 1)); done
    echo "$i"
}

block_index() {
    local i=0 id
    while id=$($PB -c "Print :Kernel:Block:$i:Identifier" "$CFG" 2>/dev/null); do
        [ "$id" = "$1" ] && { echo "$i"; return; }
        i=$((i + 1))
    done
    echo ""
}

problems=0
entries=()
prev=-1
for b in "${WANTED[@]}"; do
    i=$(add_index "$b")
    if [ -z "$i" ]; then
        echo "  ABSENT   Kernel/Add $b"
        problems=$((problems + 1)); continue
    fi
    entries+=("Kernel:Add:$i")
    printf "  %-8s Kernel/Add[%s] %-62s min=%s max=%s\n" \
        "$( [ "$(get "Kernel:Add:$i:Enabled")" = true ] && echo actif || echo inactif)" \
        "$i" "$b" "$(get "Kernel:Add:$i:MinKernel")" "$(get "Kernel:Add:$i:MaxKernel")"
    [ "$i" -gt "$prev" ] || { echo "  ORDRE    $b doit venir apres l'entree precedente"; problems=$((problems + 1)); }
    prev=$i
    [ -d "$KEXTS/${b%%/*}" ] || { echo "  MANQUANT $KEXTS/${b%%/*}"; problems=$((problems + 1)); }
done

j=$(block_index com.apple.iokit.IOSkywalkFamily)
if [ -z "$j" ]; then
    echo "  ABSENT   Kernel/Block com.apple.iokit.IOSkywalkFamily"
    problems=$((problems + 1))
else
    entries+=("Kernel:Block:$j")
    printf "  %-8s Kernel/Block[%s] com.apple.iokit.IOSkywalkFamily strategy=%s min=%s max=%s\n" \
        "$( [ "$(get "Kernel:Block:$j:Enabled")" = true ] && echo actif || echo inactif)" \
        "$j" "$(get "Kernel:Block:$j:Strategy")" "$(get "Kernel:Block:$j:MinKernel")" "$(get "Kernel:Block:$j:MaxKernel")"
fi

for b in Lilu.kext AirportBrcmFixup.kext AMFIPass.kext; do
    i=$(add_index "$b")
    [ -n "$i" ] && [ "$(get "Kernel:Add:$i:Enabled")" = true ] \
        || echo "  note     $b n'est pas actif"
done

# Kexts de ce depot, ajoutes a la fin de Kernel/Add (donc apres Lilu), pour Darwin 25 seulement.
#  - BCMWLAN-Block : sans code ; tient le dext AppleBCMWLAN a l'ecart de la carte (inoffensif).
#  - BrcmIOVAFix   : plugin Lilu ; traduit les adresses DMA des paquets d'AirPortBrcmNIC en
#                    IOVA VT-d (le noyau x86 de Tahoe ne mappe plus les mbufs dans l'IOMMU).
#                    Version compilee localement (bash wifi/BrcmIOVAFix/build.sh) si elle
#                    existe, sinon celle de wifi/BrcmIOVAFix/prebuilt/.
HERE="$(cd "$(dirname "$0")" && pwd)"
IOVA_KEXT="$HERE/BrcmIOVAFix/build/BrcmIOVAFix.kext"
[ -f "$IOVA_KEXT/Contents/MacOS/BrcmIOVAFix" ] || IOVA_KEXT="$HERE/BrcmIOVAFix/prebuilt/BrcmIOVAFix.kext"
EXTRA_NAMES=(BCMWLAN-Block.kext BrcmIOVAFix.kext)
EXTRA_SRC=("$HERE/BCMWLAN-Block.kext" "$IOVA_KEXT")
EXTRA_EXEC=("" "Contents/MacOS/BrcmIOVAFix")
EXTRA_COMMENT=("Keep AppleBCMWLAN dext off Modern Wireless cards" "Map AirPortBrcmNIC packet DMA through VT-d (macOS 26)")
EXTRA_IDX=()
for n in 0 1; do
    name=${EXTRA_NAMES[$n]}
    [ -f "${EXTRA_SRC[$n]}/Contents/Info.plist" ] || { echo "  MANQUANT ${EXTRA_SRC[$n]}"; problems=$((problems + 1)); }
    k=$(add_index "$name")
    EXTRA_IDX[$n]=$k
    if [ -n "$k" ]; then
        printf "  %-8s Kernel/Add[%s] %-62s min=%s max=%s\n" \
            "$( [ "$(get "Kernel:Add:$k:Enabled")" = true ] && echo actif || echo inactif)" \
            "$k" "$name" "$(get "Kernel:Add:$k:MinKernel")" "$(get "Kernel:Add:$k:MaxKernel")"
    else
        echo "  absent   Kernel/Add $name (ajoute par --apply)"
    fi
done

if [ "$problems" -gt 0 ]; then
    echo "$problems probleme(s). Kexts OCLP absents : reconstruire l'EFI avec OCLP ; kexts du depot absents : les compiler." >&2
    exit 1
fi

case $MODE in
    check)
        echo "Diagnostic seulement. --apply pour activer sur macOS 26."
        ;;
    apply)
        [ -f "$CFG.pre-wifi" ] || cp -p "$CFG" "$CFG.pre-wifi"
        for e in "${entries[@]}"; do
            $PB -c "Set :$e:MaxKernel ''" -c "Set :$e:Enabled true" "$CFG"
        done
        for n in 0 1; do
            name=${EXTRA_NAMES[$n]}
            rm -rf "${KEXTS:?}/$name"
            cp -R "${EXTRA_SRC[$n]}" "$KEXTS/"
            k=${EXTRA_IDX[$n]}
            if [ -z "$k" ]; then
                k=$(add_count)
                $PB -c "Add :Kernel:Add:$k dict" \
                    -c "Add :Kernel:Add:$k:Arch string x86_64" \
                    -c "Add :Kernel:Add:$k:BundlePath string $name" \
                    -c "Add :Kernel:Add:$k:Comment string '${EXTRA_COMMENT[$n]}'" \
                    -c "Add :Kernel:Add:$k:Enabled bool true" \
                    -c "Add :Kernel:Add:$k:ExecutablePath string '${EXTRA_EXEC[$n]}'" \
                    -c "Add :Kernel:Add:$k:MaxKernel string ''" \
                    -c "Add :Kernel:Add:$k:MinKernel string 25.0.0" \
                    -c "Add :Kernel:Add:$k:PlistPath string Contents/Info.plist" "$CFG"
            else
                $PB -c "Set :Kernel:Add:$k:Enabled true" "$CFG"
            fi
        done
        plutil -lint "$CFG"
        echo "Applique. Copie d'origine : $CFG.pre-wifi"
        ;;
    revert)
        for e in "${entries[@]}"; do
            $PB -c "Set :$e:MaxKernel 24.99.99" "$CFG"
        done
        for n in 0 1; do
            k=${EXTRA_IDX[$n]}
            [ -z "$k" ] || $PB -c "Set :Kernel:Add:$k:Enabled false" "$CFG"
        done
        plutil -lint "$CFG"
        echo "Retabli : la pile Wi-Fi heritee n'est plus injectee sur macOS 26."
        ;;
esac
