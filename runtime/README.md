# BasaltVR OpenXR runtime

This directory is the Windows-facing start of milestone 3. It cross-builds an x86-64 PE
runtime DLL on Apple Silicon, using the official Khronos Windows loader for the end-to-end
test. The OpenXR SDK is pinned to release 1.1.61 commit
`5267613edf3d937e3d77556a106a65c2f82b25c6` and verified by SHA-256 during CMake fetch.

The current checkpoint implements strict loader/runtime negotiation, zero-API-layer enumeration,
instance creation/destruction, instance properties, bounded live-handle registries, HMD system
discovery, primary-stereo view discovery, and a runtime JSON manifest. Its current fixed prototype
view size is 1680×1760 per eye. It advertises orientation/position tracking capability; location
flags become tracked only while a fresh ALVR HMD pose is available.

It now conditionally advertises `XR_KHR_D3D11_enable` after an in-process capability gate proves
feature level 11.0 plus D3D11 NT-handle create, reopen, GPU copy, and readback. In that environment
the runtime returns the DXGI adapter LUID, validates the application's D3D11 session binding, and
implements up to four independent three-image color swapchains with format enumeration and
acquire/wait/release. Every swapchain texture uses `D3D11_RESOURCE_MISC_SHARED_NTHANDLE`.
WhiskyWine 7.7 with Apple D3DMetal fails the gate and therefore sees zero runtime graphics
extensions; pinned DXMT v0.80 under Wine 11.10 passes it.

The runtime now also provides FIFO session events, the required session control calls, an
absolute-deadline 72 Hz `xrWaitFrame`/`xrBeginFrame`/`xrEndFrame` contract, and bounded `VIEW`,
`LOCAL`, `LOCAL_FLOOR`, and `STAGE` reference-space handles. Headless sessions stop at `SYNCHRONIZED` with `shouldRender` false.
Sessions authenticated to the native `RuntimeLink` progress through `VISIBLE`/`FOCUSED` with
`shouldRender` true and unwind those states during clean exit.

The `hello_xr` initialization surface is now implemented: bounded instance-scoped path atoms
(`xrStringToPath`/`xrPathToString`), action sets and typed actions with spec name validation,
exact suggested-binding allowlist validation for all nine OpenXR 1.0 core interaction profiles,
localized resolved-source names, interaction-profile change events, core action-set priority,
one-shot session attachment with post-attach immutability, action spaces,
`xrResultToString`/`xrStructureTypeToString`, and
`xrLocateSpace`/`xrLocateViews` with live ALVR LOCAL-from-HEAD poses, correct VIEW/LOCAL transform
composition, and calibrated Quest IPD/asymmetric FOV (with the old ±31.5 mm/symmetric 90° values
only as the pre-calibration fallback). Missing or stale HMD samples clear
tracking-dependent location flags. Because a headless session never reaches `FOCUSED`,
`xrSyncActions` returns `XR_SESSION_NOT_FOCUSED`, every action state is
inactive, no input sources are bound or localizable, and haptics validate without firing.
Connected Quest sessions additionally store Oculus Touch suggestions, snapshot buttons/profile
state at `xrSyncActions`, locate live grip action spaces, expose controller velocity through
`XrSpaceVelocity`, enumerate and localize resolved sources, and forward priority-filtered haptic
apply/stop commands to ALVR. Protocol v7's timestamped `ControllerMask` clears a missing hand's
pose and velocity immediately and permits recovery only from a newer presence/motion sample.
The first fresh head sample defines LOCAL at the viewer's horizontal position and leveled yaw.
Holding the right Quest system/Meta button for 600 ms redefines that origin at the current head
position/yaw and queues `XrEventDataReferenceSpaceChangePending` for LOCAL. Pose lookup observes
the event's `changeTime`, which follows the latest predicted display time `xrWaitFrame` has
returned, so frames already in flight retain the previous space definition. The Quest OS normally
reserves the Meta button, so this gesture is so far exercised only by the control-daemon test; the
runtime logs `right system button pressed` to stderr when ALVR forwards the button on hardware.

`xrEndFrame` now accepts stereo `XrCompositionLayerProjection` layers: it validates layer
flags, session ownership of the layer space and each subimage swapchain, per-view poses and
FOV, in-bounds image rects (`XR_ERROR_SWAPCHAIN_RECT_INVALID`), the 16-layer minimum limit
(`XR_ERROR_LAYER_LIMIT_EXCEEDED`), and that every referenced swapchain has a released image.
Quad layers are validated and accepted but not yet composed (a frame with only quads submits
nothing); extension layers are still rejected. With the Basalt DXMT fork and an authenticated
control connection, accepted projection layers are fence-gated and forwarded by IOSurfaceID to
the native Swift streamer for stereo composition and encoding. This path is machine-verified and
has a Basalt-shaped visible wired-headset diagnostic. The pinned official Khronos `hello_xr`
D3D11 application now also completes a live Quest transport/session run, including `FOCUSED`, two
eye swapchains, Touch action localization, rendering, and clean `STOPPING→IDLE→EXITING` teardown;
the companion live Quest scene is physically confirmed with fused, level/world-fixed stereo,
tracked controller response, analog squeeze, and haptics at 72 fps.
The runtime remains non-conformant and not game-ready because broader application compatibility
and game setup are unfinished.

Milestone 5's supported persistent installation path is `basaltctl bottle prepare`. It clones the
pinned engine into a Basalt-managed bottle, overlays DXMT there, copies this runtime to
`C:\basalt\runtime`, registers the bottle-local manifest, and reruns `loader_smoke.exe` with the
managed DXMT capability expected. It does not modify the generated acceptance prefixes described
below or any shared Whisky/GPTK/CrossOver engine. See [the bottle guide](../docs/BOTTLES.md).

## Prerequisites

```sh
brew install cmake mingw-w64
```

WhiskyWine is expected at Whisky's normal per-user library path for the non-graphics smoke.
Override it with `WINE` if needed.

## Build and test

From the repository root:

```sh
runtime/scripts/test-wine.zsh
```

The script:

1. Cross-builds the runtime and smoke programs as x86-64 Windows PE binaries.
2. Verifies that the DLL exports only `xrNegotiateLoaderRuntimeInterface`.
3. Runs invalid and valid negotiation plus direct instance-lifecycle checks under WhiskyWine.
4. Registers the manifest under the Khronos HKLM key in an isolated generated Wine prefix.
5. Creates a BasaltVR instance and queries its HMD, stereo views, and opaque blend mode through
   the official Khronos Windows loader before destroying it, then exercises path atoms, action
   set/action lifecycle and name validation, exact suggested bindings for all nine OpenXR 1.0 core
   interaction profiles (including cross-profile/wrong-user rejection), and the to-string calls —
   everything available without a session.

The isolated prefix is `runtime/build/wineprefix` by default. The script intentionally ignores
an ambient `WINEPREFIX` so it cannot silently change a game bottle. Override `BUILD_DIR`,
`BASALT_WINEPREFIX`, `WINE`, `CMAKE`, or `OBJDUMP` when needed. Do not point
`BASALT_WINEPREFIX` at a game bottle unless you intend to change that bottle's active OpenXR
runtime.

Run the graphics acceptance test separately:

```sh
runtime/scripts/test-dxmt.zsh
```

On its first run this command downloads and SHA-256-verifies two pinned upstream release
artifacts into the ignored `runtime/build/dxmt` tree:

- Gcenx macOS Wine 11.10 x86-64, SHA-256
  `6d0637c3526fbe7051a5f8968dbde68fbc3ac417717648b9331c46642b52173b`.
- DXMT v0.80 built-in, SHA-256
  `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`.

The script overlays only its generated Wine extraction, creates a dedicated prefix, runs the
standalone share/reopen/copy/readback probe, the fence frame-completion probe
(`dxmt_fence_probe`), and the IOSurface private-data probe (`dxmt_iosurface_probe`,
asserting absence on stock DXMT). It also verifies that the absolute waitable-timer scheduler
holds 72 Hz under Wine; the previous repeated `Sleep(14)` path measures only about 62 Hz. The
script registers Basalt's manifest only in that prefix, and
then uses the official Khronos loader to exercise reference spaces, session and interaction-profile
events, frame call ordering, exact profile bindings/localized names, action-set priority, action
spaces, velocity, controller loss/recovery, haptics, static `xrLocateSpace`/`xrLocateViews`,
projection-layer submission (accept, quad acceptance/validation, limit/rect/never-released
rejection), FIFO swapchain wait/release order, and two independent three-image D3D11 swapchains.
It also creates and submits a two-slice texture-array swapchain (Unity's Single Pass Instanced
shape), whose slices the runtime copies into per-eye IOSurface exports. It does not modify `/Applications`,
Whisky, CrossOver, or a game bottle. Rosetta 2 is required on Apple Silicon. Override the
generated prefix only with
`BASALT_DXMT_WINEPREFIX`; never point that variable at a game bottle.

For the visible end-to-end graphics test, connect an authorized Quest over USB, open its ALVR
client, stop any existing streamer, and run:

```sh
runtime/scripts/test-headset.zsh 60
```

The optional argument is the render duration in seconds (5–600). The test starts the release
streamer, runs the OpenXR/D3D11 smoke in a long visual mode, and should display a green
left-controller marker plus a pale world-fixed depth constellation in both eyes. Moving your head
tests world locking; moving the controller in depth changes marker position/size, and squeezing the
grip grows it and shifts it toward yellow. It also requires a fresh live
head pose to reach `xrLocateViews` and
prints the sampled LOCAL-space position. It temporarily overlays only the generated Wine tree with the matched
Basalt DXMT fork and restores stock DXMT during cleanup. Environment overrides are
`BASALT_HEADSET_SECONDS`, `BASALT_HEADSET_FPS`, `BASALT_HEADSET_MBPS`, and
`BASALT_HEADSET_RESOLUTION`. The wired setup sends a normal wake event before foregrounding ALVR,
but keep the headset awake while it starts if its proximity sensor puts it back to sleep. The
streamer requires a fresh Quest tracking timestamp before it declares the video path ready.

For the external-application gate, build and run Khronos' real D3D11 `hello_xr` from the pinned
official 1.1.61 source:

```sh
runtime/scripts/test-khr-hello-xr-headset.zsh
```

The target uses only small MinGW SDK compatibility headers; the upstream sample sources are not
rewritten. It has completed a live Quest run through `FOCUSED`, two D3D11 eye swapchains, localized
Touch actions, roughly 14 seconds of rendering, and clean `STOPPING→IDLE→EXITING` teardown. That is
an external-app runtime/transport/session pass. The separate long-running live Quest gate is also
physically confirmed with fused, level/world-fixed stereo, tracked controller motion, analog
squeeze, and haptics; the left controller menu button requests clean exit from `hello_xr`.

To build without running Wine (`make runtime-build` runs the same preset):

```sh
cmake -S runtime --preset mingw-release
cmake --build runtime/build --parallel
```

IDEs that read `runtime/CMakePresets.json` (VS Code CMake Tools, CLion) pick up the MinGW
toolchain and the same `runtime/build` tree the test scripts use. Configuring `runtime/` with the
host compiler does not produce a usable runtime.

If `runtime/scripts/build-dxmt-fork.zsh` has produced the Basalt DXMT fork
(`runtime/dxmt-fork`, MIT v0.80 base plus the IOSurface texture-export patches), the script
adds a fork phase: with the fork overlaid and its gate off, behavior must be
indistinguishable from stock; with `DXMT_BASALT_IOSURFACE=1`, the probes and the OpenXR
runtime smoke assert that every NT-handle shared texture — including all loader-visible
swapchain images — republishes a nonzero, per-image-distinct `IOSurfaceID` under
`BASALT_GUID_IOSURFACE_ID`, while NT-handle reopen and the GPU copy/readback checks still
pass. The phase ends with the cross-process zero-copy proof: a Wine process uploads a
known pattern into a gated texture through the immediate context, waits an
`ID3D11Fence`, and publishes the ID; a native host tool (`tests/native/iosurface_readback.c`)
maps that IOSurface by ID and must read the exact bytes. The tree is restored to the
pinned stock overlay afterwards, including when a fork-phase step fails.

## Next implementation boundary

The next app-facing and graphics slices are:

1. ~~Implement the DXMT texture-export fork~~ Done: `v0.80-basalt.1` builds reproducibly,
   the fork phase of `test-dxmt.zsh` gates it, and the cross-process zero-copy pixel proof
   passes (native `IOSurfaceLookup` readback of D3D11-rendered, fence-confirmed pixels).
2. ~~Control socket + FrameReady + streamer consumption~~ Done end to end. `pe/control.cpp`
   (protocol `pe/basalt_control_protocol.h`) connects via `BASALT_CONTROL`, probes the fork
   GUID, registers swapchain IOSurfaceIDs, and sends `FrameReady` only after the per-frame
   `ID3D11Fence` completes at `xrEndFrame`. Connected sessions report `shouldRender` true,
   progress `SYNCHRONIZED→VISIBLE→FOCUSED` (and unwind on exit), and let
   `xrSyncActions`/haptics succeed with inactive actions; headless behavior is unchanged.
   `test-dxmt.zsh` gates a 21-frame hello_xr-shaped stereo render loop whose per-frame clear
   colors the native daemon verifies byte-exact after each fence-confirmed FrameReady. It then
   repeats the smoke against the Swift streamer's `RuntimeLink`
   (`streamer/Sources/BasaltCore/RuntimeLink.swift`, via `basalt-streamer
   runtime-link-selftest`), which must acknowledge and encode at least 21 frames to H.264
   through the zero-copy IOSurface → CVPixelBuffer → VideoToolbox path. The runtime advertises
   only BGRA/BGRA-sRGB swapchains because CoreVideo cannot wrap DXMT's RGBA IOSurfaces; rejecting
   that format at negotiation prevents a silent black stream. Protocol v9 binds each frame to the exact Quest tracking timestamp
   used by its successful `xrLocateViews` call, preserves it through VideoToolbox into ALVR,
   and requires an ordered post-Metal-read acknowledgement. A strict two-frame window overlaps
   game rendering with native compose/encode while preventing latency accumulation. The control handoff also carries the
   selected per-eye stream dimensions so applications render at the target resolution instead
   of rendering 1680×1760 and immediately downscaling it.
   `runtime/scripts/test-headset.zsh` now runs that producer for a
   visible interval and sends the resulting H.264 through the live wired ALVR path. Remaining:
   the storage-mode frame-time comparison and a continuous real application/game producer.
3. ~~Feed live ALVR head poses into `xrLocateViews`/`xrLocateSpace`~~ Done: protocol v2 carries
   normalized ALVR HMD poses through a dedicated receive/demultiplex thread, with correct
   VIEW/LOCAL transforms, freshness, and tracked flags.
4. ~~Bridge Quest Touch input and haptics~~ Done for the automated controller boundary: protocol v7
   adds corrected controller grip motion/velocities, sparse buttons, active profiles, reverse
   haptic commands, and an authoritative per-frame `ControllerMask`.
   Controller samples are fairly coalesced per hand, button caches are bounded/flow-controlled,
   and ALVR control loss sends an atomic input reset so retained state cannot stick. A missing-hand
   mask immediately clears pose/velocity, while newer motion recovers tracking. Quest IPD and
   asymmetric per-eye FOV now feed `xrLocateViews` instead of prototype stereo geometry.
   All nine core profiles receive exact allowlist validation; Touch suggestions resolve into
   sync-frozen boolean/float/vector/pose states with localized source names, profile-change events,
   and core action-set priority shared by input, spaces, enumeration, and haptics. Grip action
   spaces work relative to LOCAL/VIEW and as `xrLocateViews` bases. ALVR has already predicted its
   corrected grip pose, so Basalt exposes the supplied linear/angular velocity without extrapolating
   the pose a second time. Stock ALVR does not transmit its separately-polled aim pose, so aim
   necessarily aliases grip until upstream provides distinct aim motion. The native daemon gates
   pose/velocity, immediate loss and recovery, a button change, profiles, priority, bound/localized
   sources, apply/stop haptics, and time-bounded LOCAL recentering from the Quest reset gesture.
   The pinned official Khronos `hello_xr` completes a live
   external-app transport/session run. The live Quest scene physically verifies level/world-fixed
   stereo, tracked controller response, analog squeeze, and squeeze-triggered haptics at 72 fps;
   M4 is complete.

Keeping the PE ABI side separate from the native compositor makes that platform boundary
explicit and prevents placeholder swapchains from being mistaken for a playable runtime.

### DXMT feasibility gate

`dxmt_shared_texture_probe.exe` is the first graphics gate. It uses only standard D3D11/DXGI:
create a `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` texture, create and reopen its NT handle, copy
through the GPU, stage it back to the CPU, and verify the pixels. `test-dxmt.zsh` passes this gate
and then repeats the important sharing operation on actual OpenXR-created textures. The current
WhiskyWine 7.7 + Apple D3DMetal engine fails at `QueryInterface(IDXGIResource1)` with
`E_NOINTERFACE`, as expected, so `test-wine.zsh` verifies that the runtime hides D3D11 there.

`dxmt_fence_probe.exe` verifies the Phase-1 frame-completion mechanism from
`docs/DXMT-INTEROP.md` with only public D3D11: a non-shared `ID3D11Fence` signaled on the
immediate context after queued GPU work, waited through `SetEventOnCompletion`. Under the
pinned stack the event fires only after `Signal`, values are monotonic and re-waitable, and
readback pixels are correct; `CreateFence(SHARED)` availability is reported informationally
(available at Wine 11.10 + DXMT v0.80). DXMT's `Map(DO_NOT_WAIT)` bookkeeping cleared ~1 ms
after the fence event, so the event proves GPU-queue ordering, not instant CPU-map readiness.

Passing the stock gate proves that D3D11 swapchain resources can be shared and reopened inside
Wine, but it does not by itself prove native zero-copy handoff. The pinned Basalt DXMT fork adds
that boundary through IOSurface IDs and a Wine Unix-call thunk; the fork phase and native readback
test described above now prove the separate-process handoff. Raw Objective-C object pointers are
never sent to the Swift process.
