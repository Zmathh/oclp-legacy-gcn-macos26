# Legacy GCN Metal on macOS 26 — three fixes for OCLP's `impostor.dylib`

**iMac15,1 · AMD Radeon R9 M295X (Tonga, `1002:6938`) · macOS 26.0 (25A354) · OCLP 2.5.0**

OCLP 2.5.0 already ships a macOS 26 variant of the Legacy GCN Metal shim. With it, macOS 26 boots
to a flat-coloured screen with a live cursor: Metal creates pipelines, and nothing is ever drawn.

Three separate defects cause this. Each one alone keeps the screen blank, which is why fixing any
of them in isolation appears to change nothing. With all three corrected, **the desktop works**.

Everything here was measured on the machine, with a reference run of every test on macOS 15.8 on
the same GPU. Raw logs from both systems are in `results/`.

---

## The three defects

### 1. The flag block is copied verbatim

`_fake_render` copies the 8-byte flag block of the private render pipeline descriptor as two
32-bit moves, `src +0xe0 → dest +0xd0` and `src +0xe4 → dest +0xd4`. macOS 26 **re-packs** that
block: `alphaToCoverage` and `alphaToOne` widen from 1 to 2 bits and every field above them
shifts. For the same pipeline, macOS 26 holds `0x01fe0010` where macOS 15.8 holds `0x7f8004`.
Read with the older layout, bit 2 (`isRasterizationEnabled`) comes out as 0 and **no fragment is
ever produced**.

`repack_flags()` in `src/impostor_tahoe.m` reproduces the macOS 15.8 value exactly.

### 2. `MTLRenderPipelineColorAttachmentDescriptorInternal` is not translated at all

Seventeen Metal classes implement `_descriptorPrivate`. The driver reads two of them: the render
pipeline descriptor, which the shim translates, and the colour attachment descriptor, which it
does not. macOS 26 shifts that structure's fields:

| Field | macOS 15.8 | macOS 26.0 |
|---|---|---|
| blending enabled | bit 0 | bit 0 |
| blend factors and operations | bits 1‥26 | bits 2‥27 |
| write mask | bits **27‥30** | bits **32‥35** |
| pixel format (encoded) | bits **34‥43** | bits **40‥49** |

Untranslated, the driver reads the write mask from bits 27‥30 of the macOS 26 word, which are
zero: **no colour channel is enabled**, so fragments write nothing.

`catt_translate()` reproduces the macOS 15.8 value exactly in **37 of 37** configurations —
14 pixel formats, all 16 write masks, 8 blend modes including separate alpha.

### 3. An unbound symbol in WindowServer

Once 1 and 2 are fixed, WindowServer gets far enough to composite and then crash-loops:

```
EXC_BAD_ACCESS at 0x0bad4007
isIOSurfaceSharedMetalTexture(__IOSurface*)                     AMDMTLBronzeDriver
-[BronzeMtlTexture initIOSurfaceWithDevice:descriptor:iosurface:plane:field:]
-[BronzeMtlDevice newTextureWithDescriptor:iosurface:plane:]
CoreDisplay::DisplaySurface::GetMTLTexture(...)
```

The faulting instruction dereferences a slot in the driver's binding table that holds
`0xbad4007`, dyld's unresolved-binding value. Walking the bind opcodes names the slot:
`_kIOSurfaceCreationProperties`.

**Why this happens is not established.** The symbol exists on macOS 26, and in an ordinary
process on the same system that same slot holds the correct address — none of the driver's 1473
bindings is missing (`results/macos26-test/all.log`). The poison appears only inside
WindowServer. Neither the driver nor the shim contains that constant.

So `repair.h` treats the symptom rather than the cause: at load, it walks the driver's bind
table, and for any slot still holding `0xbad4007` it writes the address `dlsym` returns for that
symbol. In a process where everything is bound correctly it changes nothing.

This third fix is a **workaround, not a diagnosis**. A maintainer who knows why dyld leaves that
binding unresolved in WindowServer would likely find a better answer.

---

## How each defect hides the others

This cost several days and is worth stating plainly.

- The flag re-packing was tested first and judged by pixel colour. The write mask was still zero,
  so no pixel could turn green and the fix looked useless. A sweep of **54 values** of the flag
  block failed the same way, for the same reason.
- The colour attachment translation was tested next with the flags still copied verbatim.
  Rasterisation was still off, so it produced zero fragments and also looked useless.
- Only counting fragment-shader invocations, then running all four combinations, separated them.

**If you re-test either of the first two fixes alone, count fragments rather than checking
pixels**, or it will seem to do nothing.

| Flag block | Colour attachment | Fragments (2 triangles) | Pixel |
|---|---|---|---|
| verbatim (shipped) | untranslated (shipped) | 0 / 0 | not written |
| **re-packed** | untranslated | **4096 / 1682** | not written |
| verbatim | **translated** | 0 / 0 | not written |
| **re-packed** | **translated** | **4096 / 1682** | **written ✓** |

macOS 15.8 gives 4096 and 1682 for the same two triangles.

---

## Also ruled out

Each cost a measurement:

- **Clipping, viewport, scissor, culling, primitive type** — 10 geometry and framing variants, all
  zero fragments, including a single point at the centre.
- **Render target format and attachments** — 12 variants including depth-only with no colour
  attachment at all.
- **The wrong Bronze bundle being installed** — the 12.7 + shim bundle *is* the macOS 26 variant;
  its 43 copy offsets match the shifts measured between the two systems. Installing Sequoia's 12.5
  bundle instead **hangs macOS 26 at boot**: its offsets are adapted to Sequoia.
- **A hand-written replacement shim being needed** — one was written from scratch and then
  compared to the shipped one instruction by instruction. All 43 copies were identical.
- **Missing symbols** — all 426 symbols the driver imports resolve on macOS 26.

---

## Measured layout shift

The private render pipeline descriptor, captured at runtime on both systems with the shipped shim
bypassed:

| macOS 15.8 | macOS 26.0 | shift |
|---|---|---|
| `+0x060` `0x10` | `+0x060` `0x10` | 0 |
| `+0x0a8` `0x1` | `+0x0b8` `0x1` | +0x10 |
| `+0x0b0` `ff × 8` | `+0x0c0` same | +0x10 |
| `+0x0b8` `0x3f800000` (1.0f) | `+0x0c8` same | +0x10 |
| `+0x0d0` `0x7f8004` | `+0x0e0` `0x01fe0010` | +0x10 |
| `+0x0f0`, `+0x0f8` | `+0x100`, `+0x108` | +0x10 |
| `+0x168`, `+0x170`, `+0x188`, `+0x190` | `+0x178`, `+0x180`, `+0x198`, `+0x1a0` | +0x10 |
| `+0x1c4` `0x1` | `+0x1dc` `0x1` | +0x18 |
| `+0x1f8` … `+0x210` | `+0x210` … `+0x228` | +0x18 |

Uniform `+0x10` from `+0xa8`, then `+0x18` from about `+0x1c0`. **The shipped shim applies both
correctly** — its copy table is not the problem.

---

## Testing without weakening the system

Library Validation rejects a locally signed shim inside WindowServer, which is a platform binary.
It does **not** apply to a locally built test program, so the same code can be injected there:

```sh
DYLD_INSERT_LIBRARIES=./both.dylib FIX_FLAGS=1 FIX_CATT=1 ./metaltest
```

`tests/both.m` interposes `MTLCreateSystemDefaultDevice`: it captures the genuine IMPs, lets Metal
load the Bronze bundle and the shipped shim swizzle, then installs its own hooks on top, always
chaining to the genuine implementation. Every measurement here was taken this way, with nothing
on the system modified and no boot argument needed.

Running the corrected shim **for real** in WindowServer is different: an ad-hoc signed build needs
`amfi_get_out_of_my_way=1`, which disables Library Validation for everything booted from that EFI.
That is acceptable on a test machine and not otherwise. A build signed with the project's chain
would not need it.

---

## Layout

```
src/     impostor_tahoe.m   the corrected shim: shipped copy table + the three fixes
         repair.h           fix 3, the binding repair
         table_*.inc        the shipped copy table, extracted from the disassembly
tests/   metaltest.m        minimal clear / pipeline / draw reproducer
         gputest.m          per stage: blit, compute to buffer, compute to texture, draws
         stages.m           vertex and fragment invocation counters
         clip.m             10 geometry and framing variants
         color.m            12 render target and draw call variants
         catt.m catt2.m     colour attachment field identification (7 then 37 configurations)
         catt_hook.m        dumps that structure as the driver receives it
         gotscan.m          counts poisoned binding slots
         gotscan2.m         walks the bind table and names every unbound slot
         both.m             each fix switchable, for the factorial table above
         sweep.m            forces any value into the flag block
         impostor_inject.m  raw structure dumps (observe / verbatim / repack / chain)
         iosurf.m key.m sym.c   IOSurface and symbol probes
results/ raw logs from both systems
```

Build a test: `clang -O2 -fobjc-arc -framework Metal -framework Foundation -o clip tests/clip.m`
Build the shim: see the header comment in `src/impostor_tahoe.m`.

Every test prints a reference result on macOS 15.8 that passes in full, so a regression on
macOS 26 is unambiguous.

---

## Status and caveats

- Fixes 1 and 2 are measured, reproducible and verified against a working system.
- Fix 3 is a workaround for a symptom whose cause is not understood.
- The shim is ad-hoc signed here and needs the project's chain to load without a boot argument.
- This is one machine, one GPU, one macOS build. Other Legacy GCN cards and other macOS 26
  releases are untested.
