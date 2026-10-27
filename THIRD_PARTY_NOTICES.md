# Third-party notices

BasaltVR is MIT-licensed. It builds on or interoperates with the projects below, which retain
their own licenses and trademarks.

| Project | Use | License | Distributed in the developer-preview app |
|---|---|---|---|
| Khronos OpenXR SDK | Headers, loader, and test applications | Apache-2.0 and accompanying Khronos terms | Selected compiled runtime/test components |
| DXMT v0.80 | D3D11-to-Metal base for the Basalt IOSurface patches | MIT | Basalt-patched runtime components when available |
| DirectXMath | Optional `hello_xr` test build | MIT | No |
| Wine | Windows compatibility runtime | LGPL-2.1-or-later and component-specific licenses | No |
| ALVR | Headset client and transport protocol | MIT | No |
| OpenComposite | OpenVR-to-OpenXR translation | GPL-3.0 | No; users build it locally (`runtime/scripts/build-opencomposite.zsh`) or supply it |
| BlackHole | Optional macOS audio loopback device | GPL-3.0 | No |

The release packager deliberately does not bundle Wine, ALVR, OpenComposite, BlackHole, games, or
store credentials. Follow each upstream project's distribution terms when obtaining those
components.

## OpenComposite

`runtime/scripts/build-opencomposite.zsh` clones OpenComposite source from
<https://gitlab.com/znixian/OpenOVR.git> at the pinned upstream commit
`cff07db75c4823afe93ed7027b03d5f7bc86f164` (the
[`openxr` branch](https://gitlab.com/znixian/OpenOVR/-/tree/openxr)), applies the patches below, and
builds `openvr_api.dll` on the user's Mac under the ignored `runtime/build` tree. No prebuilt
OpenComposite binary is downloaded, and BasaltVR does not redistribute the result.

The first six patches (`opencomposite-patches/fork`) are the commits of the
<https://github.com/Charmillionaire/OpenComposite> fork, up to `339509b9caf534fa2ced71dc71331ec3c9c3a1a6`,
that add OpenVR 2.15.6 interfaces. They are kept here as patches, with their original authorship, so
the build does not depend on that repository. One of them adds Valve's `openvr-2.15.6.h`, which is
Copyright Valve Corporation and BSD-3-Clause licensed (see `LICENSE_OPENVR.txt` in the upstream
repository).

The patch files in
[`runtime/openvr-proxy/opencomposite-patches`](runtime/openvr-proxy/opencomposite-patches) modify
OpenComposite source and contain hunks derived from it. They are distributed under OpenComposite's
license, GPLv3 or (at your option) any later version (SPDX `GPL-3.0-or-later`, as stated in
OpenComposite's README; full text at <https://www.gnu.org/licenses/gpl-3.0.html>), not under
BasaltVR's MIT license. The rest of
BasaltVR, including the OpenVR proxy in `runtime/openvr-proxy` (original code that forwards calls
to a separately installed OpenComposite DLL at run time), remains MIT.

## DXMT

The Basalt DXMT fork patches in [`runtime/dxmt-fork/patches`](runtime/dxmt-fork/patches) apply to
DXMT v0.80, the last MIT-licensed DXMT release, and are MIT-licensed like that base. See
[`runtime/dxmt-fork/README.md`](runtime/dxmt-fork/README.md).

Copies of licenses for compiled components included by the release packager are stored in
[`LICENSES`](LICENSES).
