# Wi‑Fi and Bluetooth on macOS 26

**iMac15,1 · Broadcom BCM4360 (`14e4:43a0`) + BCM20702 Bluetooth · macOS 26.0 (25A354) · OCLP 2.5.0 EFI**

**Result (2026‑10‑02):** Wi‑Fi works on macOS 26 **with VT‑d on**. Measured: 802.11ac, 5 GHz,
ping 0 % loss, 50 MB in 2.7 s (~147 Mbit/s) over `en1`. Bluetooth works natively. It takes three
parts:

1. OCLP's legacy Wi‑Fi stack (Ventura `IOSkywalkFamily`, `IO80211FamilyLegacy`,
   `AirPortBrcmNIC`), re‑enabled for Darwin 25 in `config.plist`;
2. **`BrcmIOVAFix.kext`** (this repo), because Tahoe's x86 kernel no longer maps packet buffers
   into the IOMMU. See *Root cause* below;
3. OCLP's Wi‑Fi userspace from PatcherSupportPkg **1.9.6**. 1.9.7's `IO80211` shim is mis‑signed
   and hangs boot.

The rest of this file is the investigation, in the order it happened, including what turned
out wrong.

## State before any change

| | Status | Why |
|---|---|---|
| Bluetooth | **works** | BCM20702 enumerates, firmware `v150 c9317`, LE scan and advertising run. Only the Continuity features that also need Wi‑Fi fail (`WiFiManagerClientCopyDevices failed`). |
| Wi‑Fi | **no interface** | Nothing drives `ARPT`. |

So Bluetooth needs no patch. Once Wi‑Fi is back, AirDrop and Handoff have what they need.

## Why there is no Wi‑Fi

1. **macOS 26 has no driver for this chip.** Broadcom Wi‑Fi on Tahoe is a DriverKit extension,
   `com.apple.DriverKit-AppleBCMWLAN.dext`. Its personality matches every Broadcom `0x4xxx` PCI
   device, so it does start on the BCM4360. Then it stops:

   ```
   AppleBCMWLANBusInterfacePCIe::Start_Impl: wifibt-external is not set
   AppleBCMWLANBusInterfacePCIe::Start_Impl: waitForAppleOLYHALDK failed 0xe00002c7
   DK: AppleBCMWLANBusInterfacePCIe-0x1000004e0::start(ARPT-0x100000290) fail
   ```

   It is a FullMAC driver for T2-era chips. The BCM4360 needs `AirPortBrcmNIC`, which Apple
   removed in Sonoma.

2. **The OpenCore config turns OCLP's replacement off on Darwin 25.** OCLP restores Wi‑Fi on
   Sonoma and later by injecting Ventura's `IOSkywalkFamily` 1.2.0, `IO80211FamilyLegacy` and
   `AirPortBrcmNIC`, and by blocking the system `IOSkywalkFamily`. During the Tahoe bring‑up
   (`config.plist.pre-tahoe` → `config.plist`) those four entries got `MaxKernel 24.99.99`. The
   loaded `IOSkywalkFamily` has UUID `D0A5B603…`, which is Tahoe's own. Ventura's is `035A9AD9…`.

3. **The userspace half was never installed.** OCLP 2.5's root patch for Modern Wireless installs
   `IO80211.framework`, `WiFiPeerToPeer.framework` and `wifip2pd`. PatcherSupportPkg already
   ships a Darwin 25 build of all three under `13.7.2-25`. With only the kernel half in place,
   `en1` appears, but `airportd` gets `EPERM` on `APPLE80211_IOC_POWER` and Wi‑Fi cannot be
   turned on.

## PatcherSupportPkg 1.9.7 breaks boot on Tahoe: use 1.9.6

The first attempt used 1.9.7, the release OCLP 2.5 pulls. macOS 26 then stopped halfway through
the boot progress bar, three boots in a row. WindowServer started, but `loginwindow` never did.
The kernel log says why:

```
CODE SIGNING: process 109[configd]: rejecting invalid page at address 0x108494000 from offset 0x1000
  in file "/System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211"
```

The same line appears for `powerd`, `logind`, `watchdogd`, `displaypolicyd` and every other
early daemon that links IO80211.

Of the six `13.7.2-25` files, only the `IO80211` shim differs between 1.9.6 and 1.9.7. The
difference is 5 bytes at `0x1a4d` inside `load()`: `e8 fe fd ff ff` (`call _jscSetup`) became
`90 90 90 90 90`. That matches the 2.5.0 changelog, which moved the JavaScriptCore fix for
pre‑AVX Macs into RestrictEvents. The file was not re‑signed afterwards:

```
$ codesign -v --strict IO80211      # 1.9.7
IO80211: invalid signature (code or signature have been modified)
```

`amfi_get_out_of_my_way=1` does not help: AMFI is out of the way, but the kernel still checks
each page against the code directory hashes. The 1.9.6 file is correctly ad‑hoc signed. It is
also byte‑for‑byte the same code as the laobamac/KGP variant validated on Tahoe; only the
signature blob differs. `jscSetup` does nothing useful on a Haswell, which has AVX2.

`root-patch-wifi.sh` now pins 1.9.6 and refuses any downloaded file that fails
`codesign -v --strict`. A matching SHA‑256 only proves that a file is the one published, not
that it will load. The check runs on the downloaded copy, outside the `.framework`. Once
`IO80211` sits inside the framework, `codesign` judges it as the bundle's main executable and
fails with `code has no resources but signature indicates they must be present`. That
bundle seal is something the kernel never checks. The installed copies are therefore compared
byte for byte with the verified ones before `bless`. If any differs, the files are removed
and no snapshot is created.

## Wi‑Fi refuses to turn on: the chip goes into fatal error

With both halves installed and booting cleanly, `airportd` uses `IO80211Old.dylib` and every
GET ioctl works. Only `APPLE80211_IOC_POWER` (SET) fails, with `EPERM`.

Following the 1 back through the disassembly:

| Layer | What it does | Returns |
|---|---|---|
| `IO80211SkywalkInterface::performGatedCommand` | `isCallingProcessEntitled()`: `com.apple.wlan.authentication` via AMFI, otherwise `proc_pid()==0` | 13 (`EACCES`) if refused, not 1 |
| `IO80211Controller::apple80211_ioctl_set` | dispatches through `_gSetHandlerTable` | handler's value |
| `setPower` (family) | `copyIn`, then `apple80211RequestIoctl` | 22, or the driver's value |
| `AirPort_BrcmNIC::setPOWER` | if the byte at `+0x24b0` is set: logs *"Reject power ON because of fatal error recovery failure"* | **1** (`0x320f7`) |

So the entitlement check passes, and the driver refuses because its chip went into fatal error
and recovery failed. `airportd` reports the reason it was given:
`LastDriverUnavailableReason = reinit@12=MQ_ERROR{chansts=0,fbmap=8}{rxdmastate=1,rxdmaerr=0}`.
Its events show a loop: `DRIVER_AVAILABLE` → `DUMP_LOGS` → PCI D3/D0 cycle → again, until the
driver gives up. The firmware itself loads (`IOFirmwareVersion` 7.77.111.1, MAC address read).

The first failure falls between 13:08:21.6 (`DRIVER_AVAILABLE`) and 13:08:23.4 (first D3).
At 13:08:22.17, Apple's `AppleBCMWLAN` dext attached to the same `ARPT`, in its own match
category `com.apple.wifibus.driver`. It failed (`waitForAppleOLYHALDK failed`) and was
terminated. Two candidates remain:

1. **The dext.** Being started on, then torn down from, a card that another driver is using.
   `BCMWLAN-Block.kext` tests this. It is a codeless kext that attaches an inert `IOService`
   to Modern Wireless cards in `com.apple.wifibus.driver`, with a higher probe score, so the
   dext never attaches. It does nothing else and is cheap to try. `efi-wifi.sh --apply` adds it
   for Darwin 25 only. **Result: the dext no longer starts, and the chip fails exactly as
   before. Ruled out.** The kext is kept, as it is harmless.
2. **VT‑d.** `AppleVTD` is active on this iMac. KGP validated Tahoe with `DisableIoMapper=true`
   and lists Broadcom with VT‑d on as unsolved. That quirk also stops every PCI dext from
   starting, so it cannot tell 1 and 2 apart. It has a real cost here: since Big Sur the
   BCM5701 Ethernet and since Monterey the SDXC reader need VT‑d. OCLP only swaps in
   `CatalinaBCM5701Ethernet` and `BigSurSDXC` on Macs that lack it. Try only if 1 fails.

### What the driver's own log says

Each `DUMP_LOGS` writes a CoreCapture dump under `/Library/Logs/CrashReporter/CoreCapture/`.
Its `DriverLogs/*AirPortBrcm4360_Logs*.txt.gz` is readable without root. In all 15 dumps of
2026‑10‑01, including the one from 09:40 (kernel half only, stock userspace, no AWDL), the
first fatal error is the same:

```
MQ ERROR wlc_bmac_uflush_tx_fifos: suspend dma 3 not done after 80000 us, chnstatus 0x0000
dma_ctrl: 0x3780841 lo: 0x290000 hi: 0x80000000
wl0: fatal error, reinitializing ... 802.11 reinit reason[12]
```

Before that, power‑on itself succeeds: `setPOWER rc[0]`, `wlc_up` completes, and the ARM
offload firmware starts in 46–50 ms. RX then delivers a mix of real frames and all‑zero
`runt_frame`s. The first TX FIFO flush (on the first channel change) finds the TX DMA engine
stuck. The ring address `0x00290000` is an IOMMU address, not a physical one.

Ruled out on this machine:

| Candidate | Test | Result |
|---|---|---|
| Apple's `AppleBCMWLAN` dext | `BCMWLAN-Block.kext` keeps it off `ARPT`; it no longer starts | same error |
| AWDL / userspace | 09:40 dump: stock `wifip2pd`, no AWDL interface | same error |
| PCIe ASPM | `pci-aspm-default = 0` on `ARPT` and `RP03` already | n/a |

That leaves **VT‑d**, the one difference KGP's working Tahoe setup has (`DisableIoMapper=true`).

**Tried on 2026‑10‑02 and reverted.** After `DisableIoMapper=true`, macOS 26 on this iMac no
longer reached the login window. In the two boots that left logs (09:53, 09:56), WindowServer
aborted in a loop during display setup: 5 reports between 09:54 and 09:59, `__assert_rtn` ←
`CoreDisplay_CreateDisplayForCGXDisplayDevice` ← `CGXDisplayDriverInitialize`. It came back
once the original `config.plist` was restored at 10:31.

The recovery was done from Sequoia in several steps, and the exact config of those two boots
was not kept. So the link between VT‑d off and the WindowServer abort is very likely but not
proven. Until it is, treat turning VT‑d off globally as not viable on this GPU and shim. Wi‑Fi
on Tahoe would need the legacy driver's DMA to work *with* AppleVTD, which is still open.

Recovery from both failures (EFI and root patch) is in `rescue/PROCEDURE.md`.

### Root cause: Tahoe's x86 kernel no longer maps mbufs into the IOMMU

The legacy driver's OS layer has two DMA paths:

| `AirPortBrcmNIC` function | Used for | How it gets a bus address |
|---|---|---|
| `osl_dma_alloc_consistent` | descriptor rings | `IOBufferMemoryDescriptor` + `IODMACommand(kMapped, mapper = NULL)`: a real IOVA |
| `osl_dma_map` | every TX and RX packet | `IOMbufNaturalMemoryCursor::getPhysicalSegmentsWithCoalesce`, which ends in `mbuf_data_to_physical()` → `mcl_to_paddr()` |

The two kernels differ in `mcl_to_paddr()`:

- **xnu‑11417 (Sequoia)**: `config/MASTER.x86_64` lists `config_mbuf_mcache`. The mcache
  allocator registers the whole cluster pool with the system mapper
  (`IOMapperIOVMAlloc`, then `IOMapperInsertPage` per page). `mcl_to_paddr()` returns
  `mcl_paddr[]`, i.e. an **IOVA**.
- **xnu‑12377 (Tahoe)**: `config_mbuf_mcache` is gone from `MASTER.x86_64`. The mcache code
  still exists, moved to `uipc_mbuf_mcache.c`, but is not built for x86. The zone‑based
  allocator's `mcl_to_paddr()` is `kvtophys()`, i.e. a **raw physical address** that no
  IOMMU domain maps.

With AppleVTD on, the chip can fetch its descriptors (IOVAs) but not the packet data they
point to (physical addresses):

- TX DMA sticks on the first descriptor (`s0` active, `txdmaerr=0`, 2 descriptors posted);
- RX writes land nowhere (all‑zero `runt_frame`s);
- the card's PCI status has *Received Master Abort* (bit 13) in every Tahoe dump and in no
  Sequoia dump.

This also explains why the only working Tahoe setups run with `DisableIoMapper=true`.
Tahoe's own `AppleBCM5701Ethernet` is unaffected: it maps packets with `IODMACommand` and
`IOMapper::copyMapperForDevice`, not the mbuf cursor.

**Fix: `BrcmIOVAFix.kext`**, a Lilu plugin in `wifi/BrcmIOVAFix/`. It builds without Xcode
(`bash wifi/BrcmIOVAFix/build.sh`, using the Sequoia volume's Command Line Tools if Tahoe has
none). All 307 imports resolve against the macOS 26.0 kernel and Lilu 1.7.1, and
`efi-wifi.sh --apply` installs it for Darwin 25.

**Working, 2026‑10‑02 15:19.** EFI (`efi-wifi.sh --apply`: legacy stack + `BCMWLAN-Block` +
`BrcmIOVAFix`), plus the 1.9.6 userspace (`root-patch-wifi.sh`), with **VT‑d on**:

| Check | Result |
|---|---|
| Association | Connected, 802.11ac, channel 108 (5 GHz, 40 MHz), WPA2, −60 dBm, 216 Mbit/s |
| Scan | all nearby networks listed; AWDL up (AirDrop channel 44) |
| `ping -b en1` to the gateway | 5/5, 1.4 ms average |
| `curl --interface en1`, 50 MB | 2.7 s, about 147 Mbit/s |
| CoreCapture `MQ_ERROR` dumps after boot | none |
| Ethernet (BCM5701), Bluetooth, GPU shim | unaffected |

**First boot with the kext, kernel half only, 2026‑10‑02 15:02.** It loads (its service is active, like AirportBrcmFixup's).
For the first time on Tahoe, Wi‑Fi powers on: `en1` is `On`, and `system_profiler` shows
firmware, locale ETSI/FR and the channel list. No `MQ_ERROR` dump was written after boot. Scans
still fail (`Scan Failed`, `scanResultsCount=0`), and stock Tahoe Apple80211 returns
`-3903`/`-3900` on most ioctls. The userspace half (`root-patch-wifi.sh`) is still missing at
that point. Lilu plugin `SYSLOG`s (this kext's and AirportBrcmFixup's) do not reach the unified
log on this system, so the kext's own messages are not visible yet.

It works as follows:
route `osl_dma_map`. Let the original fill the segment table
(`dmah+0x0c` count, `dmah+0x10` segments of `{u32 lo, u32 hi, u32 len}`, max 8). Then replace
each physical range by an IOVA, obtained the same way the rings get theirs:
`IODMACommand(kMapped, mapper = NULL)` on a physical `IOMemoryDescriptor`. The result is cached
per page range and never unmapped, which is what mcache did on Sequoia. Return the first
segment's 64‑bit address, as the original does.

## Is the Ventura stack safe on Tahoe?

Checked on this machine before changing anything, by comparing Mach‑O symbol tables:

| Check | Result |
|---|---|
| Wi‑Fi kexts in this EFI vs OCLP 2.5.1 payloads | byte‑identical |
| Dependencies of `IO80211FamilyLegacy` (`corecapture`, `CoreAnalyticsFamily`, AMFI, …) present in Tahoe's Boot KC | all present |
| `IO80211FamilyLegacy` imports resolved by Tahoe kernel + Ventura Skywalk | 1052 / 1052 |
| `IOSkywalkFamily` 1.2.0 imports resolved by the Tahoe kernel | 911 / 911 |
| `AirPortBrcmNIC` imports | 1104 / 1107. The 3 missing are `ether_addr_t` manglings that neither Ventura's nor Tahoe's Skywalk exports. That is the same as on Sequoia, where it works. |
| Loaded kexts linked to `IOSkywalkFamily` (`IOTimeSyncFamily`, `IOgPTPPlugin`, `AppleIPAppender`) — Skywalk symbols missing from Ventura's | 0, 0, 0 |

`IOTimeSyncFamily` is the one that matters: Ethernet (`AppleBCM5701Ethernet`) depends on it.
Tahoe kexts that *would* break against Ventura's Skywalk (`AppleBCMWLANCore`, the new
`IO80211Family`, `AppleEthernetMLX5`, `IONetworkFamily`, …) do not load on this Mac.

## Procedure

```sh
sudo diskutil mount 408679D7-722D-47FF-86E8-D935A798AEC6   # main EFI, by partition UUID (diskN changes between boots)
bash wifi/efi-wifi.sh                       # diagnostic only
bash wifi/efi-wifi.sh --apply               # drops MaxKernel on the 4 entries, adds BCMWLAN-Block + BrcmIOVAFix
# reboot, then:
bash wifi/check-wifi.sh                     # kernel section all "ok"; Wi-Fi can now power on
sudo bash rescue/rescue-tahoe.sh sauver     # this EFI boots: make it the rescue baseline
sudo bash wifi/root-patch-wifi.sh           # 6 files + new APFS snapshot
# reboot, then:
bash wifi/check-wifi.sh
```

Do it in two reboots, as above, so that a kernel‑side problem and a userspace problem cannot
be confused.

`root-patch-wifi.sh` copies the files onto the live system volume and then runs
`bless --create-snapshot`, as OCLP does. That volume already holds the GPU shim. The script
refuses to continue if the live volume's `impostor.dylib` differs from the one in use, or if
its build differs from the booted one. Files are fetched from the `1.9.6` tag and checked
against pinned SHA‑256 values and `codesign -v --strict`.

## Undoing it

| Step | Undo |
|---|---|
| EFI | `bash wifi/efi-wifi.sh --revert` (re‑caps the stack at Darwin 24, disables both kexts), or copy back `config.plist.pre-wifi`. If Tahoe no longer boots, boot the Sequoia volume (unaffected: the entries were already active on Darwin 24) and do the same from there. |
| Root patch | `sudo bash wifi/root-patch-wifi.sh --revert`. This removes the 5 framework binaries, restores `wifip2pd` and takes a new snapshot. Do **not** use OCLP's *Revert Root Patches* (`--last-sealed-snapshot`): it would also remove the GPU shim. |

### If macOS 26 no longer boots after the root patch

This is what happened with 1.9.7. The way out is the Sequoia volume ("macos stable"), booted
from the OpenCore picker. Only the system volume needs fixing; the EFI does not. The kernel
half boots fine on its own, so there is no need to revert `config.plist`.

On 2026‑10‑01 this was done from Sequoia by another Claude Code session. Its commands were not
kept here; the ones below do what `--revert` does:

```sh
diskutil list                               # macOS 26 system volume = "Untitled"; disk numbers differ under Sequoia
sudo mkdir -p /Volumes/tahoe-rw
sudo mount -o nobrowse -t apfs /dev/diskXsY /Volumes/tahoe-rw        # the volume, not its snapshot
cd /Volumes/tahoe-rw
sudo rm -f System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211 \
           System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211Old.dylib \
           System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer \
           System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeerOld.dylib \
           System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/LibSystemShim.dylib
sudo mv -f usr/libexec/wifip2pd.tahoe-orig usr/libexec/wifip2pd
cd / && sudo bless --folder /Volumes/tahoe-rw/System/Library/CoreServices --bootefi --create-snapshot
```

Then boot macOS 26 from the picker. It resumes from a snapshot holding the GPU shim and no
Wi‑Fi userspace files.

## Status and caveats

- Working end to end on this machine, with VT‑d on (measurements at the top).
- One machine and one build (25A354). Not tested: sleep/wake, AirDrop and Handoff end to end,
  hours‑long stability.
- `BrcmIOVAFix`'s own log lines are not visible: Lilu plugin `SYSLOG`s do not reach the unified
  log here. Its effect is shown by the absence of `MQ_ERROR` dumps and by working traffic.
- Without `BCMWLAN-Block`, Apple's DriverKit extension tries to start on `ARPT` and fails. That
  turned out to be harmless, but the blocker is kept.
- `wifip2pd` and the shims are ad‑hoc signed. They load here because the EFI already boots
  with `amfi_get_out_of_my_way=1` + AMFIPass for the GPU shim.
