#!/bin/bash
# Partie userspace du Wi-Fi "Modern Wireless" d'OCLP (BCM4360 / 4350 / 43602) sur macOS 26.
# Ce sont les fichiers qu'OCLP installe sur Sequoia, dans leur variante Darwin 25
# (13.7.2-25) deja publiee dans PatcherSupportPkg.
#
#   sudo bash wifi/root-patch-wifi.sh            installe, puis cree un nouveau snapshot
#   sudo bash wifi/root-patch-wifi.sh --revert   retire ces fichiers, restaure wifip2pd
#
# La pile noyau doit etre injectee par OpenCore : voir wifi/efi-wifi.sh --apply.
# Le nouveau snapshot est pris sur le volume systeme vivant, qui contient deja la couche
# GPU : le script verifie que son impostor.dylib est celui qui tourne avant d'ecrire.
set -euo pipefail

# Pas 1.9.7 (celui d'OCLP 2.5) : il retire l'appel a jscSetup() du shim IO80211 en ecrasant
# 5 octets sans re-signer. La signature ad-hoc devient fausse, le noyau rejette la page
# ("CODE SIGNING: rejecting invalid page") dans configd, powerd, logind... et le demarrage
# reste bloque a mi-barre. Les 5 autres fichiers sont identiques entre 1.9.6 et 1.9.7.
PSP_TAG=1.9.6
BASE="https://raw.githubusercontent.com/dortania/PatcherSupportPkg/$PSP_TAG/Universal-Binaries/13.7.2-25"
MNT=/System/Volumes/Update/mnt1
SHIM=System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/impostor.dylib
WIFIP2PD=usr/libexec/wifip2pd
BACKUP=usr/libexec/wifip2pd.tahoe-orig

# chemin relatif a la racine, sha256 du fichier publie au tag $PSP_TAG
PAYLOAD="\
System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211 601b1df0466d84b15e2c610590fb1aebe70681e54f4fc9e784955fb8192085d6
System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211Old.dylib 4e396ebbdad84a52104231d4f938a20c0595653d43a65a82c655c9dc38259215
System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer 8d577e72aecddf039938a7a4d80f9fe854d6ff0153402ed593c52aa27077e86f
System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeerOld.dylib 97f4d13377a1bcd57d92c8d2493be5edf759817547b7d2187049d6ec9e5fb71f
System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/LibSystemShim.dylib 4be59a19d25bd3154141f364b1a799fe22c7204367eb74ffc5fa0876e7e80170
$WIFIP2PD 00491767d8080afc3144acdc45c578e332080a048417b75d8084303d68914b78"

die() { echo "ERREUR : $*" >&2; exit 1; }

# Retire les binaires du lot et remet le wifip2pd d'origine (--revert, et echec avant bless).
remove_payload() {
    local path sum
    while read -r path sum; do
        [ "$path" = "$WIFIP2PD" ] && continue
        rm -f "$MNT/$path"
        echo "   retire $path"
    done <<<"$PAYLOAD"
    mv -f "$MNT/$BACKUP" "$MNT/$WIFIP2PD"
    echo "   $WIFIP2PD restaure"
}

MODE=install
[ "${1:-}" = "--revert" ] && MODE=revert

[ "$(id -u)" = 0 ] || die "lancer avec sudo"
[ "$(uname -r | cut -d. -f1)" = 25 ] || die "prevu pour macOS 26 (Darwin 25) uniquement"
# Sortie capturee avant grep -q : en pipe, grep -q ferme tot, l'emetteur recoit SIGPIPE
# et pipefail fait echouer le test alors que la ligne a ete trouvee.
pci=$(ioreg -r -c IOPCIDevice -k IOName)
grep -Eq '"IOName" = "pci14e4,(43a0|43a3|43ba)"' <<<"$pci" \
    || die "aucune carte Broadcom BCM4360/4350/43602 trouvee"

loaded=$(kmutil showloaded 2>/dev/null || true)
if [ "$MODE" = install ] && ! grep -q com.apple.iokit.IO80211FamilyLegacy <<<"$loaded"; then
    echo "Attention : IO80211FamilyLegacy n'est pas charge. Sans wifi/efi-wifi.sh --apply"
    echo "et un redemarrage, ces fichiers seuls ne donneront pas de Wi-Fi."
fi

# --- volume systeme vivant (le / demarre est un snapshot en lecture seule)
info=$(diskutil info -plist /)
dev=$(plutil -extract DeviceIdentifier raw - <<<"$info")
if [ "$(plutil -extract APFSSnapshot raw - <<<"$info" 2>/dev/null || echo false)" = true ]; then
    dev=${dev%s*}        # disk2s4s1 -> disk2s4
fi
if [ ! -f "$MNT/System/Library/CoreServices/SystemVersion.plist" ]; then
    mkdir -p "$MNT"
    mount -o nobrowse -t apfs "/dev/$dev" "$MNT" || die "montage de /dev/$dev impossible"
fi
echo "volume systeme : /dev/$dev monte sur $MNT"

live_build=$(plutil -extract ProductBuildVersion raw "$MNT/System/Library/CoreServices/SystemVersion.plist")
[ "$live_build" = "$(sw_vers -buildVersion)" ] \
    || die "le volume vivant est en $live_build, le systeme demarre en $(sw_vers -buildVersion)"
if [ -f "/$SHIM" ]; then
    cmp -s "/$SHIM" "$MNT/$SHIM" \
        || die "impostor.dylib du volume vivant differe de celui qui tourne : le snapshot perdrait la couche GPU"
fi

if [ "$MODE" = install ]; then
    TMP=$(mktemp -d /private/var/tmp/wifi-payload.XXXXXX)
    trap 'rm -rf "$TMP"' EXIT
    echo "== telechargement (PatcherSupportPkg $PSP_TAG, 13.7.2-25)"
    while read -r path sum; do
        mkdir -p "$TMP/$(dirname "$path")"
        curl -fsSL -o "$TMP/$path" "$BASE/$path" || die "telechargement de $path"
        [ "$(shasum -a 256 "$TMP/$path" | cut -d' ' -f1)" = "$sum" ] || die "sha256 inattendu pour $path"
        # Le sha256 dit seulement que c'est le fichier publie, pas qu'il est bien signe.
        codesign -v --strict "$TMP/$path" 2>/dev/null || die "signature invalide pour $path"
        echo "   ok  $path"
    done <<<"$PAYLOAD"

    [ -f "$MNT/$BACKUP" ] || cp -p "$MNT/$WIFIP2PD" "$MNT/$BACKUP"
    echo "== installation"
    while read -r path sum; do
        install -o root -g wheel -m 755 "$TMP/$path" "$MNT/$path"
        echo "   $path"
    done <<<"$PAYLOAD"

    # Derniere verification sur le volume cible, tant que rien n'est actif. Pas de codesign
    # ici : dans le .framework, il juge IO80211 comme executable du bundle et exige le sceau
    # des ressources ("code has no resources..."), ce que le noyau ne verifie pas. On compare
    # donc a la copie deja validee ci-dessus.
    while read -r path sum; do
        if ! cmp -s "$TMP/$path" "$MNT/$path"; then
            remove_payload
            die "copie differente une fois installee ($path) : fichiers retires, aucun snapshot cree"
        fi
    done <<<"$PAYLOAD"
else
    [ -f "$MNT/$BACKUP" ] || die "pas de sauvegarde $BACKUP : rien a restaurer"
    echo "== retrait"
    remove_payload
fi

echo "== nouveau snapshot"
bless --folder "$MNT/System/Library/CoreServices" --bootefi --create-snapshot \
    || die "bless a echoue : rien n'est encore actif, le snapshot demarre est inchange"
diskutil unmount "$MNT" >/dev/null 2>&1 || true

echo
echo "Termine. Redemarrer, puis : bash wifi/check-wifi.sh"
