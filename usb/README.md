# USB on macOS 26

macOS 26's XHCI driver reads each port's number from the `usb-port-number` property. The
`USB-Map.kext` that OCLP generates only sets `port`, so on Tahoe it does not map the ports.

`make-usb-map-tahoe.sh` copies OCLP's map and adds `usb-port-number` (same 4 bytes as `port`)
to every port of every controller. It changes nothing else apart from the bundle name and
identifier, so both kexts can stay in the same EFI:

```sh
bash usb/make-usb-map-tahoe.sh /Volumes/EFI/EFI/OC/Kexts/USB-Map.kext /Volumes/EFI/EFI/OC/Kexts
```

| `Kernel/Add` entry | MinKernel | MaxKernel |
|---|---|---|
| `USB-Map.kext` (OCLP) | as built | `24.99.99` |
| `USB-Map-Tahoe.kext` | `25.0.0` | |

On the iMac15,1 the script reproduces the map in use exactly (11 ports, `examples/iMac15,1/`),
apart from the bundle identifier. With it, the keyboard, mouse, FaceTime camera and Bluetooth
hub all enumerate on macOS 26.0.
