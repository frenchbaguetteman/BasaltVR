# DXMT texture export and IOSurface handoff protocol

Status: **zero-copy path proven end to end, 2026-07-18** — sections 1 and 2
(IOSurface-backed textures and the IOSurfaceID republish) are built as `v0.80-basalt.2`
(`runtime/dxmt-fork`, `runtime/scripts/build-dxmt-fork.zsh`) and validated by the fork
phase of `test-dxmt.zsh`: OpenXR swapchain textures under the gate republish nonzero,
per-image-distinct IOSurfaceIDs, NT-handle reopen still works via the IOSurface's own
mach port, and gate-off/stock behavior is asserted unchanged. **Acceptance test 2 passes**:
a native process (`runtime/tests/native/iosurface_readback.c`) maps the same IOSurface by
ID and reads back, byte for byte, a pattern that D3D11 under Wine uploaded and fenced
(`dxmt_iosurface_pixel_source.cpp`) — no copy crosses the process boundary. Sections 3–4
are now implemented on the runtime side (`runtime/pe/control.cpp`, wire format in
`runtime/pe/basalt_control_protocol.h`) and live-tested against a native test daemon
(`runtime/tests/native/basalt_control_test_daemon.c`): Hello/token handshake, swapchain
registration validated by `IOSurfaceLookup`, fence-gated in-order `FrameReady`, destroy
acks, and teardown all passed with the real OpenXR smoke under Wine. The consuming Swift
daemon now performs IOSurface wrapping, stereo composition, VideoToolbox encoding, and ALVR
delivery; `runtime/scripts/test-headset.zsh` provides the visible wired-Quest acceptance run.
Acceptance test 3 (the storage-mode frame-time comparison) remains outstanding. The design below was
grounded in a source audit of DXMT commit `73d42c55` (2026-07-07); file references are
into that tree, with v0.80 deltas noted where they mattered (the new unix call landed at
index 132, not 138).

## Goal and constraints

Get each OpenXR swapchain image rendered by the game (D3D11 → DXMT → Metal, inside the Wine
process) to the BasaltVR streamer daemon (separate native Swift process) zero-copy, with a
correct "contents are final for this frame" signal.

Constraints established by the M3 runtime and the audit:

1. Metal only exposes an `IOSurface` from a texture **created from one**
   (`newTextureWithDescriptor:iosurface:plane:`). DXMT at `73d42c55` contains **no IOSurface
   usage at all** (only a comment at `winemetal_unix.c:2636`), so a small DXMT fork is
   unavoidable — confirming the ARCHITECTURE risk note.
2. Raw Objective-C pointers must never cross the process boundary. DXMT's `obj_handle_t` is
   the ObjC pointer cast to `uint64_t` (`winemetal.h:28`) and is only valid in-process.
3. The Basalt runtime's swapchain textures already take DXMT's shared path:
   `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` routes to `TextureAllocationFlag::Shared` →
   `MTLDevice_newSharedTexture` (`d3d11_texture_device.cpp:382-397`, `dxmt_texture.cpp:202`,
   unix impl `winemetal_unix.c:2617`). That unix-side function is the single choke point to
   patch.
4. DXMT's existing NT-handle sharing is Wine-to-Wine only (wineserver-backed D3DKMT handle +
   mach port registered with the session bootstrap server) and carries **no synchronization**:
   keyed mutexes are a `TODO`, and imported sync objects are explicitly destroyed
   (`d3d11_texture_device.cpp:436, 641-652`). The frame-done contract must be built by us.
5. IOSurface fits the daemon as-is: `Encoder.encode` takes `CVPixelBuffer`, and
   `StereoFrameComposer` already uses IOSurface-backed pixel-buffer pools, so
   `IOSurfaceLookup` + `CVPixelBufferCreateWithIOSurface` feeds the existing encode path with
   no encoder changes.

## Fork base decision (license)

DXMT relicensed: releases **up to v0.80 are MIT** (`LICENSE.OLD`); commit `73d42c55` is
**LGPL 2.1+** (`LICENSE`, CodeWeavers copyright). Basalt currently pins the v0.80 release
binaries.

**Recommendation: base the fork on the `v0.80` tag (MIT).** It matches the runtime behavior
`test-dxmt.zsh` already validates, and keeps the project's "everything first-party MIT"
stance without adding LGPL distribution obligations. The patch surface below was mapped on
`73d42c55`; the same structures (winemetal unixcall table, `Texture::allocate`,
`CreateDeviceTextureInternal`) exist in v0.80 but line numbers and call indices must be
re-verified against the tag before implementation. If a needed fix only exists post-v0.80,
revisit — LGPL is workable (separate, source-published DLLs) but is a distribution-process
cost the project should accept deliberately, not by default.

## Design

### 1. IOSurface-backed swapchain textures (DXMT fork)

- New unix call `MTLDevice_newTextureFromIOSurface`, appended at the end of **both** dispatch
  tables (`__wine_unix_call_funcs[]` and `__wine_unix_call_wow64_funcs[]`,
  `winemetal_unix.c:2921/3063`; next free index is 138 at the audit commit). Implementation:
  `IOSurfaceCreate` (width/height/bytes-per-row, `kIOSurfacePixelFormat` = BGRA/RGBA to match
  the DXGI format) then `newTextureWithDescriptor:iosurface:plane:0`, reusing
  `fill_texture_descriptor` (`winemetal_unix.c:241`) and the existing
  `unixcall_mtldevice_newtexture` args struct unchanged.
- Trigger: config/env gate in the existing shared branch of `CreateDeviceTextureInternal`
  (`d3d11_texture_device.cpp:384-398`) — `DXMT_BASALT_IOSURFACE=1` **and**
  `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` set a new `TextureAllocationFlag::IOSurfaceBacked`
  (`dxmt_texture.hpp:39`), branched in `Texture::allocate` (`dxmt_texture.cpp:202`). The
  Basalt runtime is the only creator of such textures in a game bottle, so games see no
  behavior change; the gate is set only in Basalt-managed launch profiles.
- Constraint check (from Metal docs, flagged in the audit): IOSurface-backed textures require
  2D, one mip level, and cannot be `MTLStorageModePrivate`. Basalt swapchain images are 2D,
  mip 1, array 1, ≤1680×1760 RGBA8/BGRA8 — compatible. The storage-mode change
  (shared/managed instead of private) has an unmeasured GPU-performance cost; the acceptance
  test must include a frame-time comparison.
- The DXMT fork can allocate both RGBA8 and BGRA8 IOSurfaces, but Basalt's current OpenXR runtime
  advertises only BGRA8/BGRA8-sRGB swapchains: `CVPixelBufferCreateWithIOSurface` rejects the
  RGBA layout, while the BGRA layout is the zero-copy CoreVideo/VideoToolbox transport format.
  A projection frame goes zero-copy when its swapchains are exported BGRA images
  (`B8G8R8A8_UNORM`, `_UNORM_SRGB`, or `B8G8R8A8_TYPELESS`, which is backed by UNORM) with one
  mip, at most twice the per-view size, and positive (unflipped) image rects; the streamer crops
  each eye by the `FrameReady` image rect, so UE4's side-by-side image stays zero-copy. Quad
  layers, flipped (negative extent) rects, other formats, mip chains, depth, and larger images go
  through the runtime compositor, which draws them into its own exported BGRA images.
- PE-side data flow: `WMTTextureInfo` already round-trips through the call and has an unused
  `uint32_t reserved` out-field plus an out `mach_port` (`winemetal.h:518-532`) — the unix
  side writes `IOSurfaceGetID(surface)` into it; no new PE plumbing.

### 2. Exposing the IOSurfaceID to the Basalt PE runtime

The fork stores the ID on the texture at creation and republishes it through the **public**
`ID3D11DeviceChild::GetPrivateData` with a Basalt GUID (`BASALT_GUID_IOSURFACE_ID`). This
needs zero new COM interfaces and zero new unix calls; the Basalt runtime queries it right
after `CreateTexture2D` in the existing swapchain path. (`IOSurfaceID` is a global,
process-independent `uint32` — exactly the "no ObjC pointers" currency we want. A COM ext
interface like DXMT's `IMTLD3D11DeviceExt` pattern remains the fallback if `GetPrivateData`
proves awkward.)

The runtime's D3D11 capability gate grows a third probe: create one gated texture, read the
GUID; if absent (stock DXMT, D3DMetal), the runtime reports the daemon handoff as
unavailable and keeps today's behavior.

### 3. Frame-completion signal

Phase 1 — **CPU-confirmed, no fork sync changes, no SPI**: the runtime creates one
`ID3D11Fence` per session (public API, already implemented in `d3d11_fence.cpp:92`); at
`xrEndFrame` it calls `ID3D11DeviceContext4::Signal(fence, frameNumber)` (encodes
`encodeSignalEvent` on DXMT's queue and flushes — `d3d11_context_imm.cpp:595-605`), then
`SetEventOnCompletion(frameNumber, event)` (bridged to a Win32 event via DXMT's existing
`MTLSharedEventListener` machinery, `winemetal_unix.c:2439-2530`). A runtime thread waits the
event and only then sends `FrameReady` over the control socket. The daemon schedules Metal
composition asynchronously and replies `FrameConsumed` in order after Metal finishes reading
the source IOSurfaces. A two-frame window overlaps game rendering with compose/encode
without allowing latency to accumulate: `xrWaitFrame` blocks while two submitted frames are
unconsumed (an app that calls `xrWaitFrame` ahead of the previous `xrEndFrame` can have a third in
flight, which the runtime's pending-frame ring accommodates). Costs one CPU
wakeup (~sub-millisecond) of added signal latency; correct by construction.

Verified 2026-07-18 by `dxmt_fence_probe` (now part of `test-dxmt.zsh`) under the pinned
Wine 11.10 + DXMT v0.80 stack: the event never fires before `Signal`, fires after queued GPU
work, completed values are monotonic and re-waitable, and the copied pixels read back
correctly. One measured caveat: DXMT's CPU map bookkeeping (`Map` with `DO_NOT_WAIT`) cleared
~1 ms *after* the fence event, so the event guarantees GPU-queue ordering — which is what the
IOSurface consumer needs — not D3D11 CPU-map readiness at the same instant.

Phase 2 — **shared-event export** (optimization, measured before adoption): DXMT already has
`MTLSharedEvent_createMachPort`/`newSharedEventWithMachPort` unix calls exported from
`winemetal.dll` (`winemetal.h:1915-1923`, `winemetal_unix.c:2687-2711`). The fork registers
the session fence's event under a deterministic bootstrap name; the daemon imports the port
and waits `signaledValue >= frameNumber` directly, removing the CPU hop. This relies on the
same Metal SPI DXMT itself uses (mach-port event handles) — acceptable only because it is
already DXMT's own mechanism, and it stays out of Phase 1.

### 4. Control channel and message protocol

Transport: **loopback TCP** from the PE runtime (winsock) to the daemon. Wine's AF_UNIX
support is not something the runtime should depend on; the daemon listens on `127.0.0.1`, an
ephemeral port, and writes `<port> <token> <per-eye width> <per-eye height>` to a file the
launcher passes to the bottle via environment (`BASALT_CONTROL=path`). The dimensions make
the runtime advertise the selected stream resolution as OpenXR's recommended swapchain size,
avoiding an expensive render-then-downscale step. Legacy two-field files fall back to
1680×1760, which is also the maximum (`BASALT_CONTROL_MAX_VIEW_*`); `RuntimeLink` refuses a
larger stream resolution rather than let the game render at a size the streamer does not encode.
An optional last field lists comma-separated features (`<port> <token> [<width> <height>]
[<feature>,...]`); the only known feature, `hand_tracking`, makes the runtime advertise
`XR_EXT_hand_tracking`, and unknown features are ignored. The token (random 16 bytes, hex) must be
echoed in `Hello` so a stray local process cannot impersonate the game.

Framing: little-endian, `u32 length` + `u16 message type` + payload; strict protocol version 11 in
`Hello` (v10 added the display period in `HelloAck`; v11 added `HandSkeleton`). The runtime DLL in
the bottle and the streamer must come from the same build. Messages (runtime → daemon unless noted):

| Type | Payload | Notes |
|------|---------|-------|
| `Hello` | proto version, token, DXMT version string, session id | daemon replies `HelloAck` (accepted version, headset display period in ns that `xrWaitFrame` paces to; out of range keeps 72 Hz) or closes |
| `CreateSwapchain` | swapchain id, width, height, DXGI format, image count, per-image `IOSurfaceID` | daemon: `IOSurfaceLookup` each ID, validate dimensions/format/plane count against the message, `CFRetain` + `IOSurfaceIncrementUseCount`, reply `SwapchainAck {generation}` |
| `DestroySwapchain` | swapchain id | daemon releases retains, replies ack; runtime keeps D3D11 textures alive until the ack |
| `FrameReady` | frame number, display time, exact Quest tracking timestamp used by `xrLocateViews`, layer list: {swapchain id, image index, image rect, pose, fov} per eye | sent only after the Phase-1 fence wait; daemon wraps the IOSurface in a `CVPixelBuffer`, preserves the tracking timestamp through VideoToolbox, and feeds compose→encode→ALVR |
| `FrameConsumed` (daemon → runtime) | frame number | sent in order after asynchronous Metal composition finishes reading the source IOSurfaces; maintains a two-frame overlap window and end-to-end backpressure |
| `HeadPose` (daemon → runtime) | Quest timestamp, quaternion xyzw, position xyz | latest normalized ALVR HMD sample; Quest timestamp orders samples but is not compared with runtime `XrTime` |
| `ControllerMotion` (daemon → runtime) | Quest timestamp, hand, quaternion/position, linear/angular velocity | latest ALVR-corrected Touch grip sample; runtime-local receipt time gates freshness |
| `ButtonState` (daemon → runtime) | ALVR path id, binary/scalar tag, value | sparse retained delta; `xrSyncActions` snapshots it into resolved Touch actions |
| `InteractionProfile` (daemon → runtime) | hand, ALVR profile id | retained independently of pose freshness; Quest Touch is exposed through OpenXR |
| `InputReset` (daemon → runtime) | empty | ALVR control loss/replacement atomically clears retained controller presence/pose/velocity, profile, and button state, and the head pose with its Quest timestamp ordering (LOCAL keeps its origin) |
| `ViewConfig` (daemon → runtime) | IPD and asymmetric left/right/up/down FOV for each eye | retained Quest calibration used by `xrLocateViews` and stereo projection |
| `ControllerMask` (daemon → runtime) | Quest tracking timestamp, active-hand bit mask (bit 0 left, bit 1 right), zero reserved field | authoritative per-packet presence; a newer missing-hand bit immediately clears that hand's pose and velocity, and only newer presence/motion can recover it |
| `HandSkeleton` (daemon → runtime) | Quest tracking timestamp, hand, joint-valid mask (0 = not tracked, else all 26 bits), 26 joints of quaternion/position/radius in `XR_EXT_hand_tracking` order | latest sample per hand, in the same Quest stage frame as `ControllerMotion`; a hand-tracked hand also gets an emulated grip `ControllerMotion` and emulated `ButtonState` values |
| `Haptic` | hand, duration, frequency, amplitude | runtime→daemon; daemon packetizes this as ALVR stream ID 1 on the serialized video socket |
| `Teardown` | reason | either direction; daemon then drops all retains |

The runtime derives its natural LOCAL origin from the first fresh `HeadPose`, centering both X/Z
and leveled yaw while retaining Quest floor height. A 600 ms hold of the right system/Meta click
repeats that operation and emits `XrEventDataReferenceSpaceChangePending` for LOCAL. The previous
and new transforms straddle the event's `changeTime`, preserving frames already in flight.

Lifetime rules:

- The daemon treats `IOSurfaceID`s as **untrusted input** (IDs are global and recyclable):
  it validates width/height/format after lookup and re-validates the surface pointer
  identity per `CreateSwapchain` generation. A mismatch is a protocol error → `Teardown`.
- The daemon holds one retain + use-count per image for the swapchain's lifetime; the
  runtime guarantees the D3D11 textures outlive the `DestroySwapchain` ack, so the surfaces
  are never re-allocated while the daemon may still map them.
- Runtime-side failure policy: if the daemon is absent or the socket dies, the runtime keeps
  running exactly as today (headless, `shouldRender` false, no session loss in the
  prototype); reconnect is a later concern. The daemon ignores `FrameReady` for unknown
  swapchain ids (races with teardown are benign).
- The runtime creates its control socket non-inheritable, so a child game process (The Lab
  starts Robot Repair through OpenComposite) cannot hold its parent's connection open. A
  connection that arrives while another is live waits for its first message: an authenticated
  `Hello` replaces the live session, and anything else is dropped (at most 4 pending
  connections, 5 s `Hello` timeout).
- One runtime receiver thread owns all socket reads, publishes
  head/controller/mask/button/profile/view/reset state, and demultiplexes
  swapchain/frame acknowledgements to condition-variable waiters. A separate send lock keeps messages
  from the frame waiter and request threads byte-stream atomic. This permits asynchronous tracking
  to arrive before an expected acknowledgement without corrupting protocol state.
- OpenXR action resolution validates the exact allowlists for all nine core interaction profiles.
  Touch sources, localized names, profile-change events, action-set priority, spaces, and haptics
  are frozen consistently at `xrSyncActions`. Stock ALVR transmits a corrected, already-predicted
  grip pose plus velocity but not its separately-polled aim pose: Basalt exposes that velocity
  through `XrSpaceVelocity` without double prediction, and aim aliases grip by upstream limitation.

### 5. What ships (build and pinning)

The fork must ship a **matched set** — call codes are positional and unversioned, so
`winemetal.dll` and `winemetal.so` cannot be mixed across versions (a forked PE DLL against
a stock `.so` fails at call time): `d3d11.dll`, `dxgi.dll`, `d3d10core.dll`,
`winemetal.dll`, `winemetal.so`. Meson requires `-Dwine_install_path`; `winemetal.so` links
directly against that Wine's `winemac.so`/`ntdll.so`, so the fork **must be built against
the pinned Gcenx Wine 11.10** that `test-dxmt.zsh` installs. Tag the fork distinctly
(`vcs_tag` via `version.h.in`, surfaced in the device description, `dxmt_info.cpp:38`) —
e.g. `v0.80-basalt.2` — so the runtime can detect and pin it.

## Acceptance tests

1. **Fork gate (extends `test-dxmt.zsh`)**: with the forked DXMT and `DXMT_BASALT_IOSURFACE=1`,
   the existing swapchain smoke additionally reads `BASALT_GUID_IOSURFACE_ID` off every
   swapchain texture and asserts a nonzero, per-image-distinct ID; with the gate unset (or
   stock DXMT), the GUID is absent and the runtime hides the handoff capability.
2. **Cross-process pixel proof (the real gate)**: a D3D11 test program under Wine renders a
   known pattern into a gated texture, signals the fence, and prints the ID; a native macOS
   test tool (`streamer` test target) does `IOSurfaceLookup`, waits `FrameReady` semantics,
   and asserts the readback matches. Pass = zero-copy path proven end to end.
3. **Performance check**: frame-time comparison of private-storage vs IOSurface-backed
   swapchain rendering on the M3 Max, before making the gate default in Basalt profiles.
4. **External application gate**: `runtime/scripts/test-khr-hello-xr-headset.zsh` builds Khronos'
   real D3D11 `hello_xr` from pinned official OpenXR-SDK-Source 1.1.61 input and runs it through
   this control/IOSurface path. A live Quest run reached `FOCUSED`, created both eye swapchains,
   localized Touch actions, rendered for roughly 14 seconds, and cleanly traversed
   `STOPPING→IDLE→EXITING`. The companion live Quest scene is physically verified with fused,
   level/world-fixed stereo, tracked controller response, analog squeeze, and haptics at 72 fps.
   The runtime accepts two-slice texture-array swapchains and copies each slice into a per-eye
   IOSurface export; patch 0004 still steers Unity to its per-eye `arraySize=1` multipass path.

## Open decisions

1. ~~**Fork base**: v0.80 tag (MIT, matches pinned validation — recommended) vs `73d42c55`
   (LGPL 2.1+, newer fixes).~~ Resolved 2026-07-18: forked from the v0.80 tag as
   `v0.80-basalt.1`; patches and pinned build script live in `runtime/dxmt-fork`. The tag is
   now `v0.80-basalt.2` (adds patches 0005–0006).
2. **Phase 2 shared-event export** (Metal SPI exposure) — only after Phase 1 latency is
   measured and found wanting.
3. ~~`GetPrivateData` GUID vs a Basalt COM extension interface.~~ Resolved 2026-07-18:
   `GetPrivateData` with `BASALT_GUID_IOSURFACE_ID` `{DD807311-529E-4856-A5C0-48BED2048129}`
   works through DXMT's existing `ComPrivateData` with zero new COM surface.

## Implementation notes (v0.80 deltas from the design)

- The unix call reuses `unixcall_mtldevice_newtexture` unchanged and landed at index 132.
- NT-handle reopen is preserved under the gate: the create path returns
  `IOSurfaceCreateMachPort` in `WMTTextureInfo.mach_port`, so DXMT's existing
  bootstrap/D3DKMT registration is untouched, and a new `is_iosurface` field in
  `SharedResourceData` routes imports through `IOSurfaceLookupFromMachPort`
  (`Texture::importIOSurface`). The fork remains a matched DLL/so set.
- Only simple 2D single-sample RGBA8/BGRA8 (plus sRGB) textures take the IOSurface path;
  other NT-shared textures (mips, arrays, cubes, MSAA, other formats) keep the stock
  shared path under the gate, so games see no behavior change, and the unix call rejects
  incompatible descriptors defensively rather than tripping a Metal assertion.
- Surfaces are created with `kIOSurfaceIsGlobal` (deprecated but required): without it,
  `IOSurfaceLookup` by ID fails from another process, and the supported alternative is
  mach-port transfer, which this protocol deliberately avoids. Global surfaces are
  lookupable by any same-user process — one more reason the daemon treats IDs and surface
  properties as untrusted input (see lifetime rules).
- IOSurface-backed textures use `MTLStorageModeShared`; the acceptance-test-3 frame-time
  comparison against private storage is still outstanding.
- A second patch fixes a missing `<iomanip>` include so v0.80 builds with current
  mingw-w64 GCC.

## Risks (carried from the audit)

- Metal SPI reliance in DXMT's own sharing/event machinery could break on future macOS; the
  Phase-1 design avoids adding any new SPI dependency.
- IOSurface-backed storage-mode change has unmeasured GPU cost (acceptance test 3).
- ~~The pinned Gcenx Wine must implement the Wine-specific D3DKMT escape DXMT's shared fences
  use (`d3d11_fence.cpp:124`); verify early with a `CreateFence(SHARED)` probe under the
  pinned stack — if absent, Phase 1 still works with a non-shared fence since the wait stays
  in-process.~~ Resolved 2026-07-18: `dxmt_fence_probe` shows `CreateFence(SHARED)` and
  `ID3D11Fence::CreateSharedHandle` both succeed under the pinned stack.
- wow64/arm64ec dispatch tables must both be extended; Basalt only targets x86_64 Wine
  today.
