# OpenComposite patches

`runtime/scripts/build-opencomposite.zsh` applies these patches, in file-name order, to
OpenComposite source cloned from <https://github.com/Charmillionaire/OpenComposite> at the pinned
commit `339509b9caf534fa2ced71dc71331ec3c9c3a1a6`. The script fails if a patch does not apply.
What each patch fixes is described in [the OpenComposite guide](../../../docs/OPENCOMPOSITE.md).

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
distributed under OpenComposite's license, not under BasaltVR's MIT license. The rest of BasaltVR,
including the proxy in [`runtime/openvr-proxy`](..), is MIT-licensed.

BasaltVR does not redistribute OpenComposite binaries, and apart from the hunks in these patches it
contains no OpenComposite source. Users build OpenComposite locally with these patches. See also
[THIRD_PARTY_NOTICES.md](../../../THIRD_PARTY_NOTICES.md).
