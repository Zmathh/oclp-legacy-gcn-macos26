#!/bin/bash
# Etat du Wi-Fi et du Bluetooth apres redemarrage. Lecture seule, sans sudo.
#   bash wifi/check-wifi.sh          etat
#   bash wifi/check-wifi.sh --log    + messages de BrcmIOVAFix depuis le demarrage (lent)
set -uo pipefail

VENTURA_SKYWALK=035A9AD9-6CDE-362F-8DEC-B664BC6431EC   # IOSkywalkFamily 1.2.0 d'OCLP

ok()  { echo "  ok    $*"; }
bad() { echo "  NON   $*"; }

echo "== noyau"
loaded=$(kmutil showloaded 2>/dev/null)
sky=$(grep ' com.apple.iokit.IOSkywalkFamily ' <<<"$loaded")
if grep -q "$VENTURA_SKYWALK" <<<"$sky"; then
    ok "IOSkywalkFamily de Ventura (injecte par OpenCore)"
else
    bad "IOSkywalkFamily de Tahoe : le Block / l'injection OpenCore n'est pas actif"
fi
for id in com.apple.iokit.IO80211FamilyLegacy com.apple.driver.AirPort.BrcmNIC as.lvs1974.AirportBrcmFixup com.zmathh.BrcmIOVAFix; do
    grep -q " $id " <<<"$loaded" && ok "$id" || bad "$id non charge"
done
for id in com.apple.iokit.IOTimeSyncFamily com.apple.iokit.AppleBCM5701Ethernet; do
    grep -q " $id " <<<"$loaded" && ok "$id (lie a IOSkywalkFamily)" || bad "$id non charge"
done
drv=$(ioreg -r -n ARPT -d 2 2>/dev/null | grep -Eo 'AirPort_BrcmNIC[^ ]*' | head -1)
[ -n "$drv" ] && ok "ARPT pilote par $drv" || bad "aucun pilote AirPort sur ARPT"
arpt=$(ioreg -r -n ARPT -d 2 2>/dev/null)
if grep -q "<class IOService," <<<"$arpt"; then
    ok "dext AppleBCMWLAN tenu a l'ecart (BCMWLAN-Block)"
else
    bad "BCMWLAN-Block absent : le dext AppleBCMWLAN peut prendre la carte"
fi

reg=$(ioreg -l -w0 2>/dev/null)
if grep -q "<class AppleVTD," <<<"$reg"; then
    echo "  info  VT-d actif (AppleVTD)"
else
    echo "  info  VT-d desactive (DisableIoMapper)"
fi

echo "== userspace"
for f in /System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211Old.dylib \
         /System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeerOld.dylib \
         /usr/libexec/wifip2pd.tahoe-orig; do
    [ -f "$f" ] && ok "$f" || bad "$f absent (wifi/root-patch-wifi.sh)"
done
for p in airportd wifip2pd; do
    pgrep -x "$p" >/dev/null && ok "$p tourne" || bad "$p ne tourne pas"
done

echo "== interfaces"
port=$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/{getline; print $2}')
if [ -n "$port" ]; then
    ok "Wi-Fi sur $port ($(networksetup -getairportpower "$port" | sed 's/.*: //'))"
else
    bad "pas de port Wi-Fi"
fi
eth=$(networksetup -listallhardwareports | awk '/Hardware Port: Ethernet/{getline; print $2; exit}')
[ -n "$eth" ] && ok "Ethernet $eth : $(ifconfig "$eth" 2>/dev/null | awk '/status:/{print $2}')"

echo "== bluetooth"
system_profiler SPBluetoothDataType 2>/dev/null | grep -E '^ +(State|Chipset|Firmware Version):' | head -3 | sed 's/^ */  /'

if [ "${1:-}" = "--log" ]; then
    echo "== BrcmIOVAFix (noyau, depuis le demarrage)"
    /usr/bin/log show --last boot --style compact --predicate 'process == "kernel" AND eventMessage CONTAINS "BrcmIOVAFix"' 2>/dev/null \
        | grep -v '^Timestamp' | sed -E 's/^[0-9-]+ ([0-9:.]+) [A-Za-z]+ +kernel\[[^]]*\] /\1 /' | tail -20
fi
