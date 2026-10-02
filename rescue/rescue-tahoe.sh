#!/bin/bash
# Retour a un macOS 26 qui demarre. Pensé pour etre lance depuis Sequoia (« macos stable »),
# demarre par l'autre OpenCore, quand Tahoe ne demarre plus. Fonctionne aussi depuis Tahoe.
#
#   sudo bash rescue-tahoe.sh          etat : configs EFI disponibles, fichiers Wi-Fi presents
#   sudo bash rescue-tahoe.sh sauver   apres un demarrage REUSSI : config.plist -> config.plist.last-good
#   sudo bash rescue-tahoe.sh efi      remet config.plist.last-good (garde l'actuelle en .failed-DATE)
#   sudo bash rescue-tahoe.sh wifi     retire le root patch Wi-Fi du volume systeme de Tahoe
#                                      et cree un nouveau snapshot (depuis un AUTRE macOS seulement)
#   sudo bash rescue-tahoe.sh audio    retire AppleHDA.kext, remet les kernel collections sauvegardees
#                                      par audio/root-patch-audio.sh, nouveau snapshot (AUTRE macOS)
#
# Les identifiants sont des UUID : les numeros diskN changent d'un macOS a l'autre.
set -euo pipefail

EFI_PART_UUID=408679D7-722D-47FF-86E8-D935A798AEC6   # EFI de l OpenCore principal (disk0s1 ou disk1s1 selon le demarrage)
TAHOE_SYS_UUID=0A395E32-5B65-4C0D-B88A-0EFFB0AAF251  # volume systeme « Untitled » (macOS 26)
TAHOE_DATA_UUID=6AEDE14F-D9C4-3788-8FAC-FD32C4838D47 # volume de donnees « Untitled - Donnees »
RW=/Volumes/tahoe-rw
HDA=System/Library/Extensions/AppleHDA.kext
KC=System/Library/KernelCollections

WIFI_FILES="\
System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211
System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211Old.dylib
System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer
System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeerOld.dylib
System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/LibSystemShim.dylib"
WIFIP2PD=usr/libexec/wifip2pd
BACKUP=usr/libexec/wifip2pd.tahoe-orig

die() { echo "ERREUR : $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "lancer avec sudo"

MODE=${1:-etat}
case $MODE in etat|sauver|efi|wifi|audio) ;; *) die "commande inconnue : $MODE (etat, sauver, efi, wifi, audio)" ;; esac

# --- EFI principal
efi_dev=$(diskutil info -plist "$EFI_PART_UUID" 2>/dev/null | plutil -extract DeviceIdentifier raw - 2>/dev/null) \
    || die "partition EFI $EFI_PART_UUID introuvable"
diskutil mount "$efi_dev" >/dev/null 2>&1 || true
efi_mnt=$(diskutil info -plist "$efi_dev" | plutil -extract MountPoint raw - 2>/dev/null || true)
[ -n "$efi_mnt" ] && [ -f "$efi_mnt/EFI/OC/config.plist" ] || die "EFI $efi_dev non monte ou sans EFI/OC/config.plist"
OC="$efi_mnt/EFI/OC"

# Resume d'une config : quirk VT-d et pile Wi-Fi heritee (plutil -p liste les cles par ordre alpha).
summary() {
    local io
    io=$(/usr/libexec/PlistBuddy -c "Print :Kernel:Quirks:DisableIoMapper" "$1" 2>/dev/null || echo "?")
    plutil -p "$1" | awk -v io="$io" '
        /^ *[0-9]+ => \{/ { b="" }
        /"BundlePath" =>/ { b=$3; gsub(/"/,"",b) }
        /"Enabled" =>/    { en=$3 }
        /"MaxKernel" =>/  { mx=$3; gsub(/"/,"",mx)
                            if (b=="IO80211FamilyLegacy.kext")
                                wifi = (en!="true") ? "inactive" : (mx=="") ? "Tahoe" : "Sequoia seulement"
                            if (b=="BCMWLAN-Block.kext") blk=(en=="true") ? "actif" : "inactif"
                            if (b=="BrcmIOVAFix.kext") iova=(en=="true") ? "actif" : "inactif" }
        END { printf "DisableIoMapper=%s  Wi-Fi heritee=%s  BCMWLAN-Block=%s  BrcmIOVAFix=%s", io, (wifi?wifi:"absente"), (blk?blk:"absent"), (iova?iova:"absent") }'
}

echo "EFI principal : $efi_dev monte sur $efi_mnt"
for f in "$OC"/config.plist "$OC"/config.plist.*; do
    [ -f "$f" ] || continue
    printf "  %-34s %s  %s\n" "$(basename "$f")" "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f")" "$(summary "$f")"
done

# --- volume systeme de Tahoe
sys_dev=$(diskutil info -plist "$TAHOE_SYS_UUID" 2>/dev/null | plutil -extract DeviceIdentifier raw - 2>/dev/null) \
    || die "volume systeme de Tahoe $TAHOE_SYS_UUID introuvable"
root_dev=$(diskutil info -plist / | plutil -extract DeviceIdentifier raw -)
booted_on_tahoe=no
case $root_dev in "$sys_dev"|"$sys_dev"s*) booted_on_tahoe=yes ;; esac
echo "Systeme Tahoe : /dev/$sys_dev (demarre dessus : $booted_on_tahoe)"

mount_tahoe_rw() {
    if [ ! -f "$RW/System/Library/CoreServices/SystemVersion.plist" ]; then
        mkdir -p "$RW"
        mount -o nobrowse -t apfs "/dev/$sys_dev" "$RW" || die "montage de /dev/$sys_dev impossible"
    fi
    local v
    v=$(plutil -extract ProductVersion raw "$RW/System/Library/CoreServices/SystemVersion.plist")
    case $v in 26.*) ;; *) die "$RW est en macOS $v, pas 26 : mauvais volume" ;; esac
}

case $MODE in
    etat)
        if [ "$booted_on_tahoe" = no ]; then
            mount_tahoe_rw
            n=0; while read -r p; do [ -f "$RW/$p" ] && n=$((n + 1)); done <<<"$WIFI_FILES"
            echo "  fichiers Wi-Fi du root patch presents : $n / 5$( [ -f "$RW/$BACKUP" ] && echo ', sauvegarde wifip2pd presente')"
            echo "  AppleHDA.kext : $( [ -d "$RW/$HDA" ] && echo present || echo absent)"
        fi
        [ -f "$OC/config.plist.last-good" ] \
            || echo "Pas encore de config.plist.last-good : lancer « sauver » apres un demarrage reussi."
        ;;
    sauver)
        cp -p "$OC/config.plist" "$OC/config.plist.last-good"
        cp -p "$OC/config.plist" "$OC/config.plist.good-$(date +%Y%m%d-%H%M)"
        echo "Sauve : config.plist.last-good ($(summary "$OC/config.plist.last-good"))"
        # Le kit voyage avec l'EFI : accessible depuis n'importe quel macOS qui monte cette partition.
        here=$(cd "$(dirname "$0")" && pwd)
        mkdir -p "$efi_mnt/rescue-tahoe"
        cp "$here/rescue-tahoe.sh" "$efi_mnt/rescue-tahoe/"
        [ -f "$here/PROCEDURE.md" ] && cp "$here/PROCEDURE.md" "$efi_mnt/rescue-tahoe/"
        echo "Kit copie dans $efi_mnt/rescue-tahoe/"
        ;;
    efi)
        [ -f "$OC/config.plist.last-good" ] || die "pas de config.plist.last-good ; restaurer a la main une des copies listees"
        plutil -lint "$OC/config.plist.last-good" >/dev/null || die "config.plist.last-good invalide"
        failed="$OC/config.plist.failed-$(date +%Y%m%d-%H%M)"
        cp -p "$OC/config.plist" "$failed"
        cp -p "$OC/config.plist.last-good" "$OC/config.plist"
        echo "Remis : config.plist.last-good. L'ancienne est gardee dans $(basename "$failed")."
        ;;
    wifi)
        [ "$booted_on_tahoe" = no ] \
            || die "demarre sur Tahoe : utiliser plutot sudo bash wifi/root-patch-wifi.sh --revert"
        mount_tahoe_rw
        echo "== retrait du root patch Wi-Fi sur $RW"
        while read -r p; do rm -f "$RW/$p"; echo "   retire $p"; done <<<"$WIFI_FILES"
        if [ -f "$RW/$BACKUP" ]; then
            mv -f "$RW/$BACKUP" "$RW/$WIFIP2PD"
            echo "   $WIFIP2PD d'origine remis"
        else
            echo "   pas de $BACKUP : wifip2pd laisse tel quel"
        fi
        bless --folder "$RW/System/Library/CoreServices" --bootefi --create-snapshot \
            || die "bless a echoue : snapshot non cree"
        diskutil unmount "$RW" >/dev/null 2>&1 || true
        echo "Nouveau snapshot cree. Redemarrer sur macOS 26 via l'OpenCore principal."
        ;;
    audio)
        [ "$booted_on_tahoe" = no ] \
            || die "demarre sur Tahoe : utiliser plutot sudo bash audio/root-patch-audio.sh --revert"
        data_dev=$(diskutil info -plist "$TAHOE_DATA_UUID" | plutil -extract DeviceIdentifier raw -) \
            || die "volume de donnees de Tahoe introuvable"
        diskutil mount "$data_dev" >/dev/null 2>&1 || true
        data_mnt=$(diskutil info -plist "$data_dev" | plutil -extract MountPoint raw - 2>/dev/null || true)
        [ -n "$data_mnt" ] || die "volume de donnees de Tahoe non monte"
        # Sauvegarde la plus recente prise AVANT une installation d'AppleHDA.
        save=""
        for d in $(ls -1t "$data_mnt/Users/Shared/rescue-tahoe-kc/" 2>/dev/null); do
            grep -q "avant install" "$data_mnt/Users/Shared/rescue-tahoe-kc/$d/README.txt" 2>/dev/null \
                && { save="$data_mnt/Users/Shared/rescue-tahoe-kc/$d"; break; }
        done
        [ -n "$save" ] && [ -f "$save/SystemKernelExtensions.kc" ] \
            || die "aucune sauvegarde de kernel collections dans $data_mnt/Users/Shared/rescue-tahoe-kc/"
        echo "sauvegarde utilisee : $save ($(cat "$save/README.txt"))"
        mount_tahoe_rw
        echo "== retrait d'AppleHDA.kext et remise des kernel collections"
        rm -rf "${RW:?}/${HDA:?}"
        cp -p "$save"/*.kc "$save"/*.elides "$RW/$KC/"
        bless --folder "$RW/System/Library/CoreServices" --bootefi --create-snapshot \
            || die "bless a echoue : snapshot non cree"
        diskutil unmount "$RW" >/dev/null 2>&1 || true
        echo "Nouveau snapshot cree. Redemarrer sur macOS 26 via l'OpenCore principal."
        ;;
esac
