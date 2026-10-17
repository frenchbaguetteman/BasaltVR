# Basalt DXMT fork

Patches for the DXMT texture-export boundary defined in `docs/DXMT-INTEROP.md`: OpenXR
swapchain textures created with `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` become IOSurface-backed
so the BasaltVR streamer daemon can map the same pixels zero-copy in a separate native
process.

## Base and license

The fork base is the upstream **v0.80 tag** (commit `589adb780354b461645b29999cefaf533594ee99`),
the last MIT-licensed DXMT release; later upstream commits are LGPL 2.1+ (see the fork-base
decision in `docs/DXMT-INTEROP.md`). All patches in `patches/`, including 0005 and 0006, follow
the license of that base: they are MIT-licensed, the same terms as DXMT v0.80
([`LICENSES/DXMT-MIT.txt`](../../LICENSES/DXMT-MIT.txt)) and the rest of BasaltVR.

## Patches

- `patches/0001-basalt-iosurface-export.patch` — the feature:
  - New unix call `MTLDevice_newTextureFromIOSurface` (index 132, appended to both dispatch
    tables): creates a texture from a fresh IOSurface, or imports one via
    `IOSurfaceLookupFromMachPort`. Returns the global `IOSurfaceID` in
    `WMTTextureInfo.reserved` and an `IOSurfaceCreateMachPort` send right in `.mach_port`.
  - `TextureAllocationFlag::IOSurfaceBacked` plus `Texture::importIOSurface`; the allocation
    records its `iosurfaceID`.
  - Gate in the D3D11 shared-texture path: with **`DXMT_BASALT_IOSURFACE=1`** in the
    environment, `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` textures take the IOSurface path.
    The IOSurface's own mach port feeds DXMT's existing bootstrap/D3DKMT registration, so
    NT-handle `CreateSharedHandle`/`OpenSharedResource1` reopen keeps working
    (`SharedResourceData` gained an `is_iosurface` field; the fork ships as a matched
    DLL/so set exactly like stock DXMT).
  - The texture republishes its `IOSurfaceID` through public
    `ID3D11DeviceChild::GetPrivateData` under `BASALT_GUID_IOSURFACE_ID`
    `{DD807311-529E-4856-A5C0-48BED2048129}` (4 bytes, little-endian `uint32`).
  - Only simple 2D, single-mip, non-array, single-sample textures in `RGBA8`/`BGRA8`
    (plus sRGB) take the IOSurface path; every other NT-shared texture keeps the stock
    `MTLSharedTextureHandle` path even under the gate, so games see no behavior change.
    The unix call also rejects incompatible descriptors defensively (nil texture, not a
    Metal assertion). Without the gate, behavior is bit-for-bit stock.
- `patches/0002-fix-missing-iomanip-include.patch` — build fix for current mingw-w64 GCC
  (`std::setfill`/`std::setw` used without `<iomanip>`).
- `patches/0003-exportless-winemac-metal-view.patch` — creates a normal AppKit/Metal
  child view for single-window games when an otherwise-compatible Wine build hides DXMT's
  optional private mac-driver exports.
- `patches/0004-force-unity-openxr-multipass.patch` — reports
  `VPAndRTArrayIndexFromAnyShaderFeedingRasterizer` as unavailable. Unity OpenXR then uses
  its multipass fallback, matching Basalt's independent 2D IOSurface eye swapchains and
  preventing single-pass fullscreen lighting from reaching only one eye.
- `patches/0005-metal-27-atomic-memory-flags.patch` — build fix for the Xcode 27 Metal
  toolchain. Its compiler rejects DXMT's four-argument `__metal_atomic_fetch_add_explicit` call
  in `air_tessellation.metal` ("too few arguments ... expected 5, have 4"). The patch passes
  `__METAL_MEMORY_FLAGS_NONE__` as the fifth argument when that macro exists; older toolchains
  keep the four-argument call.
- `patches/0006-msaa-8x-fallback-to-supported-sample-count.patch` — D3D11 feature level 11_0
  promises 8x MSAA; Apple GPUs support at most 4x. Stock DXMT fails `CreateTexture2D` for 8x
  (`sample count 8 is not supported`). Source 2 Auto-Fidelity (seen in The Lab's Robot Repair)
  creates 8x eye targets without checking the result and then renders nothing (an all-zero
  eye texture). With the patch, the Metal texture uses the largest supported count (4x) while
  the D3D11 description keeps 8, `CheckMultisampleQualityLevels` still reports 0 levels for 8x,
  and `Texture2DMS` loads wrap the sample index into the real count (a resolve shader built
  for 8 samples reads each of the 4 samples twice, so its average stays correct). The shader
  cache version goes from 18 to 19. `runtime/tests/dxmt_msaa_probe.cpp`, run by
  `test-dxmt.zsh`, checks creation, clear/draw and resolve with an 8x depth target, and the
  8-sample resolve shader; stock v0.80 fails it and the fork must pass it.

## Building

```sh
runtime/scripts/build-dxmt-fork.zsh
```

Pins and verifies: DXMT v0.80 by commit, LLVM `llvmorg-15.0.7` by commit (built from source
on the first run — tens of minutes), and the Wine 8.16 build-tools tarball by SHA-256 (the
same tree DXMT's own CI used to produce the official v0.80 release binaries, which
`test-dxmt.zsh` already validates under the pinned Gcenx Wine 11.10). Prerequisites beyond
`runtime/README.md`: `brew install meson ninja` and an Xcode with the Metal toolchain.

Output: `runtime/build/dxmt/fork-install/{x86_64-windows/*.dll,x86_64-unix/winemetal.so}`,
tagged `v0.80-basalt.1` in the source checkout. The PE DLLs and winemetal.so are a matched
set — never mix them with stock v0.80 binaries. After a rebuild, install the new set into an
existing bottle with `basaltctl bottle install-dxmt NAME` (or `bottle prepare NAME`).

## Verifying

`runtime/tests/dxmt_iosurface_probe.cpp` asserts both sides: with `DXMT_BASALT_IOSURFACE=1`
and `BASALT_EXPECT_IOSURFACE=1`, NT-handle textures must republish nonzero, distinct
IOSurfaceIDs; without the gate the GUID must be absent. `test-dxmt.zsh` remains the stock
regression gate.
