#!/bin/bash
# Make OCLP's USB-Map.kext usable on macOS 26.
#
#   bash usb/make-usb-map-tahoe.sh /path/to/EFI/OC/Kexts/USB-Map.kext [out-dir]
#     -> <out-dir>/USB-Map-Tahoe.kext (default out-dir: current directory)
#
# macOS 26's XHCI driver maps ports by the `usb-port-number` property. OCLP's map only sets
# `port`. This copies the kext and adds `usb-port-number` (same 4 bytes as `port`) to every
# port of every personality. Nothing else changes, apart from the bundle name and identifier,
# so both kexts can sit in the same EFI:
#   USB-Map.kext        MaxKernel 24.99.99
#   USB-Map-Tahoe.kext  MinKernel 25.0.0
set -euo pipefail

SRC=${1:?usage: make-usb-map-tahoe.sh USB-Map.kext [out-dir]}
OUT=${2:-.}
PLIST_IN="$SRC/Contents/Info.plist"
[ -f "$PLIST_IN" ] || { echo "no Info.plist in $SRC" >&2; exit 1; }

DST="$OUT/USB-Map-Tahoe.kext"
rm -rf "$DST"
mkdir -p "$DST/Contents"
cp "$PLIST_IN" "$DST/Contents/Info.plist"
P="$DST/Contents/Info.plist"
plutil -convert xml1 "$P"

id=$(plutil -extract CFBundleIdentifier raw -o - "$P")
plutil -replace CFBundleIdentifier -string "${id}-Tahoe" "$P"
plutil -replace CFBundleName -string "USB-Map-Tahoe" "$P"

added=0
for root in IOKitPersonalities_x86_64 IOKitPersonalities; do
    plutil -extract "$root" xml1 -o /dev/null "$P" 2>/dev/null || continue
    # Personality names never contain dots in OCLP maps (e.g. "iMac15,1-XHC1").
    for pers in $(/usr/libexec/PlistBuddy -c "Print :$root" "$P" | awk '/^    [^ ].* = Dict \{$/ {print $1}'); do
        base="$root.$pers.IOProviderMergeProperties.ports"
        plutil -extract "$base" xml1 -o /dev/null "$P" 2>/dev/null || continue
        for port in $(/usr/libexec/PlistBuddy -c "Print :$root:$pers:IOProviderMergeProperties:ports" "$P" | awk '/^    [^ ].* = Dict \{$/ {print $1}'); do
            data=$(plutil -extract "$base.$port.port" raw -o - "$P")
            plutil -remove "$base.$port.usb-port-number" "$P" 2>/dev/null || true
            plutil -insert "$base.$port.usb-port-number" -data "$data" "$P"
            added=$((added + 1))
        done
    done
done

plutil -lint "$P" >/dev/null
echo "$DST: usb-port-number added to $added ports"
echo "In config.plist: USB-Map.kext MaxKernel 24.99.99, USB-Map-Tahoe.kext MinKernel 25.0.0."
