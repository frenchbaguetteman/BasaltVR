# OpenComposite

OpenVR games (SteamVR API, such as The Lab or Half-Life: Alyx) reach Basalt's OpenXR runtime
through [OpenComposite](https://gitlab.com/znixian/OpenOVR/-/tree/openxr), which replaces the
game's `openvr_api.dll`. OpenComposite is GPL-3.0. BasaltVR does not download, link, or
redistribute an OpenComposite binary; it builds one locally from pinned source. You can also
supply your own matching-bitness `openvr_api.dll`.

Native OpenXR games (Beat Saber 1.29.4 and later) do not need OpenComposite.

## Build

```sh
brew install mingw-w64 cmake ninja
runtime/scripts/build-opencomposite.zsh        # -> runtime/build/opencomposite/out/openvr_api.dll
```

The script also needs `git` and `python3`. It:

1. Clones upstream OpenComposite, <https://gitlab.com/znixian/OpenOVR>, into the ignored
   `runtime/build/opencomposite/src` and checks out the pinned commit
   `cff07db75c4823afe93ed7027b03d5f7bc86f164` (branch `openxr`), with the `libs/openxr-sdk` and
   `libs/glm` submodules at the commits that commit pins.
2. Applies the patches in `runtime/openvr-proxy/opencomposite-patches`: first the six in its
   `fork/` folder, then Basalt's own, each set in file-name order. It fails if one does not apply.
   A later run reuses the checkout when the commit and the patch set are unchanged, and refuses to
   touch a checkout with local changes.
3. Cross-builds a 64-bit, D3D11-only DLL with the repository's MinGW toolchain file, linking the
   MinGW runtime statically (a game prefix has no MinGW DLLs). The DLL reports the version
   `basalt-cff07db75c48`.
4. Fails unless the result is a PE32+ x86-64 DLL, its export table matches
   `runtime/openvr-proxy/opencomposite-exports.txt` exactly, the generated stubs use the MSVC
   struct-return ABI (patch 0004), and it imports no MinGW runtime DLL. It prints the imports,
   exports, and SHA-256.

Upstream `cff07db` registers at most `IVRSystem_022`, `IVRCompositor_028`, `IVRInput_010`,
`IVROverlay_027`, and `IVRApplications_007`, and aborts on any other version. The six `fork/`
patches are the commits of a former GitHub fork of the `openxr` branch, kept as patches with their
original authors so the build does not depend on that repository. They add the OpenVR 2.15.6
interfaces `IVRSystem_026`, `IVRCompositor_029`, `IVRInput_011`, `IVROverlay_028`, and
`IVRApplications_008`, and answer the `IVRIPCResourceManagerClient` probe instead of aborting.
Current Half-Life: Alyx builds request these.

## Basalt patches

Basalt's own patches are in
[`runtime/openvr-proxy/opencomposite-patches`](../runtime/openvr-proxy/opencomposite-patches)
and apply after the `fork/` patches.

| Patch | Fixes |
|---|---|
| 0001 `implement-GetPosesForFrame` | `IVRCompositor::GetPosesForFrame` was `STUBBED()` (abort). It now returns the latest render poses; `GetLastPosePredictionIDs` always reports ID 0. Recent Half-Life: Alyx builds call it every frame through `IVRCompositor_029` (xrizer issue #448). |
| 0002 `GetD3D9AdapterIndex-default-adapter` | `IVRSystem::GetD3D9AdapterIndex` returns adapter 0 instead of aborting (xrizer PR #426). |
| 0003 `mingw-d3d11-build` | MinGW-w64 cross-build with D3D11 only: no Vulkan, OpenGL, or D3D12, so no prebuilt Vulkan SDK. Also fixes MSVC-only constructs (ATL, the `WIN32` define, `std::wstring` file streams, `fsync`, `CD3D11_VIEWPORT`, single-pass link order, `#pragma comment(lib)`), and the static-initialization order of the log stream, without which the MinGW DLL crashes while it loads. |
| 0004 `msvc-aggregate-return-abi` | MSVC passes `this` first and the hidden return pointer second for a C++ method that returns a struct; MinGW GCC passes them the other way round. Every OpenVR method that returns `HmdMatrix34_t`, `HmdMatrix44_t`, `HmdColor_t`, `HiddenAreaMesh_t`, or `DistortionCoordinates_t` (for example `IVRSystem::GetEyeToHeadTransform`) therefore wrote its result over OpenComposite's own object, and MSVC-built games crashed on the next call. The header splitter and stub generator now declare these vtable slots in MSVC's convention when building with MinGW. |
| 0005 `legacy-frame-timing-num-frame-presents` | `GetFrameTiming` filled the struct only when it had the `IVRCompositor_018` size (200 bytes), so the `IVRCompositor_012` to `_014` struct (168 or 176 bytes) stayed zero. Old SteamVR Unity plugins set `Time.fixedDeltaTime` from `m_nNumFramePresents`; zero made The Lab's Secret Shop run thousands of physics steps per frame (about 1 fps). The old layout is now filled too. |

## The OpenVR proxy

Valve's own `openvr_api.dll` exports five interface accessors that the public OpenVR SDK does not
declare (`LiquidVR`, `VRControlPanel`, `VRHeadsetView`, `VRPaths`, `VRVirtualDisplay`) plus
`VR_GetRuntimePath`. OpenComposite exports none of them, so a game that imports one cannot load
with OpenComposite alone. Half-Life: Alyx uses `IVRControlPanel_006` (OpenComposite issue #176),
which Valve's `VRControlPanel` export returns.

`runtime/openvr-proxy` builds a small proxy `openvr_api.dll`:

- every OpenComposite export (the list in `opencomposite-exports.txt`) is a linker forwarder to
  `openvr_api_opencomposite.dll`;
- `VRControlPanel` and `VRHeadsetView` call OpenComposite's `VR_GetGenericInterface` with
  `IVRControlPanel_006` and `IVRHeadsetView_001` and a non-null error pointer (OpenComposite
  dereferences it before `VR_Init`), and return null on error;
- `VRPaths`, `LiquidVR`, and `VRVirtualDisplay` return null without asking OpenComposite, which
  would abort on interface versions it does not implement;
- `VR_GetRuntimePath` reports the directory that holds OpenComposite.

The proxy uses an OpenComposite that is already loaded, or else loads the copy next to itself; it
never searches the DLL path. Build and test it under the pinned Wine 11.10:

```sh
runtime/scripts/test-openvr-proxy.zsh          # -> runtime/build/openvr-proxy/bin/openvr_api.dll
```

The test loads the proxy through an import table, as a game does, first next to a fake
OpenComposite with the same exports (calls must reach it), then next to the real build (every
export must resolve, `VR_IsRuntimeInstalled` must work, and the Alyx `opencomposite.ini` must be
accepted). `--fake-only` skips the real build. No headset is needed. The proxy is original
BasaltVR code under the MIT license; it contains no OpenComposite source.

A game needs the proxy only if it imports one of the Valve-only names. Check with
`x86_64-w64-mingw32-objdump -p <file> | grep -A20 openvr_api` on each executable and DLL; C# games
also name their entry points in `DllImport` attributes.

## Install

The BasaltVR app's **Prepare VR** does all of this for one game, including Half-Life: Alyx, from
the two local builds above, with backups, restore, and a status that notices a Steam update; see
[the management app](MANAGEMENT.md). The command below is the manual path.

`basaltctl opencomposite install` writes OpenComposite (and optionally the proxy) over one game's
`openvr_api.dll`, below the bottle's prefix, and writes `opencomposite.ini` next to it. The first
original DLL is kept as `openvr_api.dll.basalt-original`. It refuses to replace an `opencomposite.ini` that
Basalt did not write, and a target, backup, or ini that is a symbolic link.

| Option | Effect |
|---|---|
| `--artifact PATH` | The OpenComposite DLL (required) |
| `--target PATH` | The game's `openvr_api.dll` inside the managed prefix (required) |
| `--proxy PATH` | Install the proxy as `openvr_api.dll` and OpenComposite beside it as `openvr_api_opencomposite.dll`. A later install without `--proxy` removes that file. |
| `--preset default` | `initUsingVulkan=false` (Basalt's runtime offers only `XR_KHR_D3D11_enable`). The default. |
| `--preset alyx` | Also `invertUsingShaders=true`; without it, Alyx's menus and overlays appear upside down. Requires `--proxy`. |
| `--ini KEY=VALUE` | Set another option (repeatable), for example `--ini supersampleRatio=0.8` |

OpenComposite's `openxr` branch aborts the game on an unknown option or a malformed value, so the
installer accepts only the options that branch parses: `renderCustomHands`, `handColour`,
`supersampleRatio`, `haptics`, `admitUnknownProps`, `logGetTrackedProperty`, `stopOnSoftAbort`,
`dx10Mode`, `enableHiddenMeshFix`, `invertUsingShaders`, `initUsingVulkan`,
`hiddenMeshVerticalScale`, and `logAllOpenVRCalls`. Booleans take `true`/`on`/`enabled` or
`false`/`off`/`disabled`, colours `#rrggbb`. Older Basalt versions wrote `enableAudio=false`,
which this branch rejects.

A Steam update or "Verify integrity of game files" restores Valve's DLL; run the install again.

### Example: The Lab

The Lab (Steam app 450390) has three programs, each with its own 64-bit `openvr_api.dll`: the hub
and most mini-games (`TheLab/win64/TheLab.exe`, Unity), Secret Shop
(`SecretShop/win64/SecretShop.exe`, older Unity), and Robot Repair
(`RobotRepair/bin/win64/vr.exe`, Source 2). None of them imports a Valve-only export, so it needs
no proxy, and the `default` preset is enough: the runtime flips negative image rects itself.

```sh
LAB="$HOME/Library/Application Support/BasaltVR/Bottles/pcvr/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/The Lab"
basaltctl profile add the-lab --bottle pcvr --source steam \
  --exe 'C:\Program Files (x86)\Steam\steamapps\common\The Lab\TheLab\win64\TheLab.exe' \
  --arg -popupwindow --cwd "$LAB/TheLab/win64" --env SteamAppId=450390 --env SteamGameId=450390
for dll in TheLab/win64/TheLab_Data/Plugins/x86_64/openvr_api.dll \
           SecretShop/win64/SecretShop_Data/Plugins/openvr_api.dll \
           RobotRepair/bin/win64/openvr_api.dll; do
  basaltctl opencomposite install the-lab \
    --artifact runtime/build/opencomposite/out/openvr_api.dll --target "$LAB/$dll"
done
```

(`basaltctl` here is `swift run --package-path streamer basaltctl` or the release binary in
`streamer/.build/release`.) To play, start Steam with `basaltctl steam start steam`, start the
streamer with `--runtime` as in [the bottle guide](BOTTLES.md#launch), and run
`basaltctl run the-lab --control-file PATH`. Robot Repair, which the hub starts, inherits the
Basalt environment from `TheLab.exe` and opens its own runtime connection.

### Example: Half-Life: Alyx

Alyx needs the proxy and the `alyx` preset. This is the expected setup; it has not been tested on
a headset (see [compatibility](COMPATIBILITY.md)). Forwarded exports are resolved by the Windows
loader in the directory of `hlvr.exe`, so install into `game/bin/win64`:

```sh
alyx_bin="$HOME/Library/Application Support/BasaltVR/Bottles/pcvr/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/Half-Life Alyx/game/bin/win64"
basaltctl opencomposite install alyx-steam \
  --artifact runtime/build/opencomposite/out/openvr_api.dll \
  --proxy runtime/build/openvr-proxy/bin/openvr_api.dll \
  --preset alyx \
  --target "$alyx_bin/openvr_api.dll"
```

## Pre-flight without a headset

Run the game against a streamer with no headset to catch OpenComposite aborts before a headset
session: run the streamer without `--wired`/`--wireless` and without audio, then the profile:

```sh
basalt-streamer --runtime /tmp/basalt-control-test
basaltctl run the-lab --control-file /tmp/basalt-control-test
```

Then check:

- OpenComposite's log, `drive_c/users/<user>/AppData/Local/OpenComposite/logs/opencomposite.log`
  in the prefix: `Extension: XR_KHR_D3D11_enable`, the session reaching state 5 (`FOCUSED`), and
  no abort. A "Missing interface" message box means the game asked for an interface version this
  build does not implement.
- The streamer log: `OpenXR runtime connected`.
- With `BASALT_RUNTIME_LOG` set, the runtime's own `Basalt OpenXR` lines, including those of a
  child program such as Robot Repair.

Without a headset, Unity games log `GetPoseActionData ... InvalidDevice` many times per second
(no controllers); that is expected.

Interface versions that the pinned build does not implement and that appear in The Lab's
binaries: `IVRControlPanel_004`, `IVRResources_001`, `IVRTrackedCamera_003`, and, in the SteamVR
Unity plugin, `IVRDebug_001`, `IVRIOBuffer_002`, `IVRNotifications_002`,
`IVRSpatialAnchors_001`, and `IVRTrackedCamera_006`. None was requested in The Lab sessions run
so far.

## What OpenComposite needs from the runtime

From an audit of the upstream `openxr` branch (`cff07db`). "Abort" means a message box, then the
game ends.

- **Extensions:** requested only if enumerated. Without a D3D11 (or Vulkan) extension, abort.
- **Spaces:** creates STAGE, LOCAL, and VIEW and aborts on any failure; STAGE is the default
  tracking space for `xrLocateViews` and layers. `xrGetReferenceSpaceBoundsRect(STAGE)` may return
  `XR_SPACE_BOUNDS_UNAVAILABLE`; any other error aborts.
- **Swapchains:** created in the game texture's format (as `_UNORM_SRGB`, or `_UNORM` if linear or
  more than 8 bits per channel), size, and mip count, without calling
  `xrEnumerateSwapchainFormats` on D3D11. Creation failure aborts. Live swapchains: two eyes, one
  skybox, one per textured overlay.
- **Layers:** one projection layer plus quad layers with source alpha. Zero-layer frames occur.
  `imageRect` can have a non-zero offset and, with flipped bounds, a negative height (the skybox
  always does this).
- **Sessions:** a temporary session on a temporary D3D11 device first, then the real one on the
  game's device; spaces, action spaces, and hand trackers are not destroyed before
  `xrDestroySession`, and the same action sets are attached again to the new session.
- **Input:** suggested bindings, `xrSyncActions`, `xrGetCurrentInteractionProfile`,
  `xrCreateActionSpace`, and `xrEnumerateBoundSourcesForAction` abort on any failure. Haptic calls
  pass game values through unchecked. `xrLocateHandJointsEXT` must not fail for an untracked hand.

Basalt's runtime covers each of these: STAGE space, BGRA-only advertisement with a compositor for
every other format and for quads and flipped rects, up to 16 swapchains, action-set re-attach,
haptic normalization, and `isActive = XR_FALSE` for untracked hands. A projection layer in exported
BGRA swapchains (one mip, at most twice the per-view size) with positive image rects skips the
compositor even when the rects are offset: the streamer crops each eye by its `imageRect`. See
[the runtime README](../runtime/README.md).

## License

OpenComposite is GPLv3 or later. The patch files contain hunks derived from OpenComposite source
and are distributed under OpenComposite's license, not BasaltVR's MIT license; see
[the patch README](../runtime/openvr-proxy/opencomposite-patches/README.md) and
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
