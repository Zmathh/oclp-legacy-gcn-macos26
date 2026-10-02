# Audio on macOS 26

**iMac15,1 · Intel HDA controller (`HDEF`, `8086:8c20`) · macOS 26.0 (25A354)**

**Result (2026‑10‑02):** internal speakers and the internal microphone work. `system_profiler
SPAudioDataType` lists *Built-in Output* and *Built-in Microphone*, and `afplay` plays.

## Why there is no sound

macOS 26 no longer ships `AppleHDA.kext`. The only Intel Macs that Tahoe supports have a T2
chip, which handles their audio, so Apple dropped the HDA driver. On a non‑T2 Mac, `HDEF` has no
driver and CoreAudio sees no device at all.

## Fix

Put `AppleHDA.kext` back on the system volume and rebuild the kernel collections:

```sh
sudo bash audio/root-patch-audio.sh "/Volumes/<macOS 15 volume>/System/Library/Extensions/AppleHDA.kext"
```

Use the kext from an installed macOS 15. Here that is Sequoia 15.8 on the second disk: version
600.2, an Apple bundle with its `_CodeSignature` seals intact. The KGP OCLP fork installs the one
from macOS 26.0 beta 1 (25A5279g, also 600.2), the last Tahoe build that still had it. Its
binaries differ from 15.8's, and its copy in their PatcherSupportPkg has no bundle seals.

Checked before installing, against macOS 26.0's own files:

| Check | Result |
|---|---|
| Declared dependencies (`IOAudioFamily`, `IOHDAFamily` (bundled), `OSvKernDSPLib`, `vecLib.kext`, `AppleEFINVRAM`, `AppleSMBusController`, `IONDRVSupport`, `IOGraphicsFamily`, `IOACPIFamily`, `IOPCIFamily`) | all present on 26.0 |
| External imports of the six kext binaries, against the 26.0 kernel and those kexts | 1013 / 1013 resolved (same for 26.0 beta 1's copy) |
| Kernel Debug Kit merged into the system volume (needed by `kmutil`) | yes, already done for the GPU patch |

What the script does:

1. It checks the build, the GPU shim and the KDK, as `wifi/root-patch-wifi.sh` does.
2. It copies the current kernel collections to `/Users/Shared/rescue-tahoe-kc/<booted snapshot>/`
   on the data volume (about 465 MB).
3. It installs the kext, then runs `kmutil create --allow-missing-kdk --volume-root … --update-all
   --variant-suffix release`, the command OCLP uses on Ventura and later.
4. If `kmutil` or `bless` fails, it puts back the old kernel collections and the old kext, and
   creates no snapshot.
5. Otherwise it runs `bless --create-snapshot`.

`--revert` removes the kext the same way.

## If macOS 26 does not boot afterwards

`AppleHDA` lands in the System KC. OpenCore's `Kernel/Block` cannot reach that collection, so the
way back is to restore the saved collections. From the Sequoia volume:

```sh
sudo bash /Users/Shared/rescue-tahoe/rescue-tahoe.sh audio
```

This removes `AppleHDA.kext`, copies back the most recent collections saved *before an install*,
and takes a new snapshot.

## Not tested

- Headphone jack, line in/out, HDMI/DisplayPort audio through the GPU (`AppleGFXHDA`).
- Sleep/wake with audio playing.
