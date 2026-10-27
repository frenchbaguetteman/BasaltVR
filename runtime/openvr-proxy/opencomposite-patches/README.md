# OpenComposite patches

`runtime/scripts/build-opencomposite.zsh` clones upstream OpenComposite from
<https://gitlab.com/znixian/OpenOVR.git> and checks out commit
`cff07db75c4823afe93ed7027b03d5f7bc86f164` (branch `openxr`). It then applies, with
`git apply --index`, first the patches in [`fork/`](fork) and then Basalt's own patches below, each
set in file-name order. The script fails if a patch does not apply. No third-party fork is cloned.

## fork/ patches

The six files in `fork/` are the commits of <https://github.com/Charmillionaire/OpenComposite>
that sit directly on upstream `cff07db`, up to its commit `339509b9caf534fa2ced71dc71331ec3c9c3a1a6`.
They were exported unchanged with `git format-patch --full-index --binary cff07db..339509b`, so the
original author, date, and message of each commit are kept. They add the OpenVR 2.15.6 interfaces
(IVRSystem_026, IVRCompositor_029, IVRInput_011, IVROverlay_028, IVRApplications_008), answer the
IVRIPCResourceManagerClient probe, and add the fork's Windows CI workflow file
(`.github/workflows/build-windows.yml`, unused by the build). They do not change the submodule
pins.

| Patch | Fork commit |
|---|---|
| `fork/0001-feat-add-modern-OpenVR-2.x-interfaces-support-and-Wi.patch` | `c062882` |
| `fork/0002-fix-resolve-compilation-errors-in-BaseCompositor-and.patch` | `924de5d` |
| `fork/0003-fix-complete-OpenVR-2.x-interface-support-build-erro.patch` | `7ccaf3e` |
| `fork/0004-fix-correct-two-self-inflicted-errors-from-previous-.patch` | `b652f54` |
| `fork/0005-fix-replace-STUBBED-with-graceful-fallbacks-in-new-O.patch` | `b3332d3` |
| `fork/0006-fix-treat-IVRIPCResourceManagerClient-as-optional-pr.patch` | `339509b` |

`fork/0001` is large (about 316 KB) because it adds Valve's `OpenVRHeaders/openvr-2.15.6.h`
(6166 lines, SteamVR 2.15.6). That header carries only the line "Copyright Valve Corporation"; Valve
publishes OpenVR under the BSD 3-Clause license, the same text as upstream's `LICENSE_OPENVR.txt`
(SPDX `BSD-3-Clause`). The other five fork patches are 2 to 8 KB each.

## Basalt patches

| Patch | Summary |
|---|---|
| `0001-implement-GetPosesForFrame.patch` | `IVRCompositor::GetPosesForFrame` returns the latest render poses instead of aborting |
| `0002-GetD3D9AdapterIndex-default-adapter.patch` | `IVRSystem::GetD3D9AdapterIndex` returns adapter 0 instead of aborting |
| `0003-mingw-d3d11-build.patch` | D3D11-only MinGW-w64 cross-build |
| `0004-msvc-aggregate-return-abi.patch` | MSVC calling convention for OpenVR methods that return structs |
| `0005-legacy-frame-timing-num-frame-presents.patch` | `GetFrameTiming` fills the IVRCompositor_012 to _014 struct |

## License

OpenComposite is free software under the GNU General Public License, version 3 or (at your
option) any later version (SPDX `GPL-3.0-or-later`; <https://www.gnu.org/licenses/gpl-3.0.html>).
These patch files modify OpenComposite source and contain hunks derived from it, so they are
distributed under OpenComposite's license, not under BasaltVR's MIT license. This includes the
`fork/` patches, except that the added Valve header keeps Valve's BSD-3-Clause terms. The rest of BasaltVR,
including the proxy in [`runtime/openvr-proxy`](..), is MIT-licensed.

BasaltVR does not redistribute OpenComposite binaries, and apart from the hunks in these patches it
contains no OpenComposite source. Users build OpenComposite locally with these patches. See also
[THIRD_PARTY_NOTICES.md](../../../THIRD_PARTY_NOTICES.md).
