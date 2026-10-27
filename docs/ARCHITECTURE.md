# BasaltVR Architecture

Goal: reimplement the MoltenVR pipeline — Windows PCVR games running under Wine on Apple
Silicon, streamed to an ALVR headset client — as an open-source project.

## First playable product slice

The first supported game is modded Beat Saber. A management app should discover or accept a
Beat Saber/BSManager installation, maintain a dedicated Wine bottle and launch profile, show
only streaming settings supported by the connected headset, and start the complete stack with
a small number of clicks. This vertical slice takes priority over broad game compatibility.

Acceptance criteria:

1. Select or discover a modded Beat Saber installation.
2. Select the paired headset and choose bitrate, refresh rate, resolution, and codec.
3. Click Launch; Basalt prepares the bottle/runtime and starts streaming.
4. Head and controller tracking, gameplay audio, and haptics work without manual terminals.

## System overview

```
┌─────────────────────────── macOS (Apple Silicon) ───────────────────────────┐
│                                                                              │
│  ┌──────────── Wine process (native macOS process) ────────────┐            │
│  │                                                              │            │
│  │  Windows VR game (PE binary)                                 │            │
│  │    │ D3D11                        │ OpenVR (SteamVR games)   │            │
│  │    ▼                              ▼                          │            │
│  │  DXMT ──► Metal textures      OpenComposite                  │            │
│  │                                   │ OpenXR                   │            │
│  │                                   ▼                          │            │
│  │              BasaltVR OpenXR runtime (thin PE side)          │            │
│  └───────────────────────│──────────────────────────────────────┘            │
│                          │ IOSurface handoff + control socket                │
│                          ▼                                                   │
│  BasaltVR streamer daemon                                                    │
│    frame queue ─► VideoToolbox H.264 (low-latency) ─► ALVR transport ────────┼──► headset
│    OpenXR poses/actions ◄─ tracking/input/haptics ◄── ALVR transport ◄───────┼─── (ALVR client)
│    game audio (BlackHole loopback) ─► ALVR audio stream                      │
│                                                                              │
│  Management app (SwiftUI): wizard, bottle manager, game detection, launcher  │
└──────────────────────────────────────────────────────────────────────────────┘
         transport: Wi-Fi (UDP) or USB (adb forward + TCP)
```

## The key architectural insight

Wine on macOS is a **native macOS process** — the Windows game, DXMT, and the Metal device
all live in a process that can use macOS frameworks directly. So the OpenXR runtime does not
need marshalling across a VM boundary: game-rendered textures are already Metal textures, and
they can be shared with the streamer daemon zero-copy via **IOSurface**.

The runtime therefore splits in two:

1. **PE side** (loaded by the game through the OpenXR loader manifest): implements the OpenXR
   ABI the game sees, exposes `XR_KHR_D3D11_enable` (games under OpenComposite bind D3D11),
   and obtains the underlying Metal texture for each swapchain image from DXMT.
   ⚠ This requires a DXMT interop path (D3D11 texture → IOSurface/MTLTexture) — the same
   reason MoltenVR bundles a specific DXMT build. May require a small DXMT patch; DXVK grew
   an equivalent API for ALVR/Linux.
2. **Host daemon**: owns the compositor (layer composition, reprojection later), the encoder,
   the ALVR transport, audio, and pose/input state. Communicates with the PE side over a Unix
   socket (control) + shared IOSurfaces (frames).

## Component map: reuse vs. build

| Component | Source | Work |
|-----------|--------|------|
| Wine build (GPTK/WhiskyWine) | reuse | packaging + bottle tooling |
| D3D11 → Metal | reuse DXMT | interop patch for swapchain export |
| OpenVR → OpenXR | reuse OpenComposite | build for Wine/PE, config |
| Headset client | reuse stock ALVR client | none (that's the point) |
| Streaming transport | reuse/port ALVR streamer protocol | significant: ALVR's streamer targets Windows/Linux; port session, sockets, packetization |
| Video encode | **build** (this repo, M1 ✅) | VideoToolbox low-latency H.264 |
| OpenXR runtime | **build** | the big one — see M3 |
| Audio capture | build (thin) | BlackHole device capture → ALVR audio |
| USB transport | **built** (thin) | physical-device detection + `adb forward` + ALVR TCP mode |
| Management app | **build** | SwiftUI |

## Milestones

### M1 — Encoder + transport skeleton ✅ (in this repo)
`streamer/`: ScreenCaptureKit capture → VideoToolbox H.264 in low-latency rate-control mode
→ Annex-B over TCP, viewable in ffplay. Proves the encode path and its latency profile;
capture is a stand-in for runtime-submitted frames.

### M2 — ALVR bridge ✅ (Wi-Fi UDP and USB TCP video validated on Quest 3)
Implement the streamer side of the ALVR 20.x protocol: mDNS/UDP discovery, session
negotiation (JSON session config), stream setup, video NAL packetization, time sync, and the
uplink (tracking, input, stats). Acceptance: the stock ALVR client on a headset shows the Mac
desktop from M1. This replaces `TCPServer` behind the same broadcast interface.
Reference: `alvr/server_core` in the ALVR repo (MIT).

Done so far (`BasaltCore/Discovery.swift` and `AlvrControl.swift`, behind `--discover`): UDP broadcast
discovery — the 56-byte client beacon on port 9943 (`"ALVR"` magic padded to 16 bytes,
u64 LE protocol id, 32-byte NUL-padded hostname; verified against ALVR v20.14.0
`client_core`/`server_core` sources) is parsed. The streamer connects back to TCP 9943,
reads the big-endian length-framed bincode `ClientConnectionResult`, and checks that its
protocol ID agrees with discovery. The complete legacy/extended capability payload is decoded,
including resolution, refresh rates, microphone rate, codec features, and preference flags.
Reads and variable-length fields are timeout- and size-bounded.
`AlvrSession.swift` selects a conservative first Beat Saber profile (90 Hz when advertised)
and serializes the exact bincode-framed `StreamConfigPacket`. The same TCP socket is retained
to send that configuration and `StartStream`, then validate the client's `StreamReady` reply.
After `StreamReady`, Basalt retains the control connection, connects stream port 9944, and sends
VideoToolbox H.264 access units using ALVR's stream ID 3, 18-byte shard prefix, video header,
and 1,404-byte legacy-compatible wire limit. Wi-Fi uses UDP. `--wired` detects an authorized
physical Quest, creates ADB forwards for the headset's TCP 9943/9944 listeners, negotiates
`wired: true`, launches the client, and transports the same ALVR shards as a length-framed TCP
stream in both directions. Packet reconstruction plus UDP and TCP loopback tests cover the
downlink and uplink. Wired TCP uses a separate 1 MiB send/receive buffer and a single 50 ms
whole-access-unit deadline; a partial write poisons and closes the connection instead of allowing
later shards to desynchronize the stream. Send reports expose wire rate, access-unit size, write
duration, IDRs, and repeated tracking timestamps. Because ScreenCaptureKit only generates a new
surface when desktop content changes, a latest-frame pacer advances the encoder at video cadence
with fresh host-clock timestamps and no catch-up queue; unchanged stereo output is reused. The
temporary desktop is rendered as a smaller virtual monitor in both halves of
the side-by-side frame; live `ViewsConfig` packets supply the Quest's IPD and asymmetric FOV for
placement. Capture and negotiation use the same supported refresh rate. Encoder, kernel UDP, and
Quest decoder queues are explicitly bounded. Client IDR requests recover packet loss without
waiting for the normal keyframe interval and are rate-limited to prevent a decoder-saturation
keyframe storm. The uplink extracts Quest tracking timestamps and the head pose, but the temporary
flat desktop preview does not apply that pose: correct world anchoring requires M3's per-eye 3D
renderer, and attempting to fake it with a 2D image transform caused visible tilt. `ClientStatistics`
reports display FPS, input-to-display, decode, decoder-queue, and vsync measurements. Those values
are diagnostic rather than a trustworthy desktop motion-to-photon measurement until capture and
rendering use the corresponding pose. The selected encoder bitrate remains fixed. Foveated encoding
remains disabled because Basalt must first implement the corresponding encoder-space warp; merely
setting the negotiated flag would distort the image. A live M3 Max → USB → Quest 3 run completed the
control handshake, reached `StreamReady`, and held 72 fps at capture/encode, USB transport, and
Quest display for an extended sample. Quest pipeline latency remained roughly 52–58 ms, with USB
writes below 3 ms. A follow-up comparison held approximately 72 fps with the low-latency preset
and reduced the Quest-reported decoder queue from roughly 10–12 ms to 3–4 ms, while reported
input-to-display latency fell from roughly 55–58 ms to 47–51 ms. A separate quality-preset run
held approximately 72 fps at 1344×1408 per eye (2688×1408 encoded), with decode near 21 ms and
steady local capture-to-encode latency near 12 ms. These samples validate the preset plumbing and
show available headroom, but do not establish subjective head-motion quality or sustained thermal
behavior. Ultra latency is the explicit one-frame, reduced-history option for latency-focused
USB sessions; low remains the safer default. Comparisons should change one setting at a
time from a cool headset. Per-eye resolution and conservative decoder-buffering presets are shared
model values exposed through the CLI today and intended for management-app launch profiles. The
runtime path now consumes full HMD/controller tracking and game swapchain textures; the remaining
product work is the real game/launcher boundary.

### M3 — OpenXR runtime skeleton ✅
A runtime the OpenXR loader can enumerate (JSON manifest + `xrNegotiateLoaderRuntimeInterface`),
implementing: instance/system/session lifecycle, `XR_KHR_D3D11_enable` graphics binding,
swapchain create/acquire/wait/release backed by IOSurface-shareable textures, frame loop
(`xrWaitFrame`/`xrBeginFrame`/`xrEndFrame`), and stereo view configuration with poses fed from
M2's tracking. Acceptance: `hello_xr -g D3D11` under Wine renders into our runtime and the
frames reach the headset.

M3.0 through the first graphics checkpoint are complete: `runtime/` cross-builds a genuine x86-64 Windows PE DLL on Apple Silicon,
pins the official Khronos OpenXR SDK/loader to release 1.1.61, and exports only the required
unmangled `xrNegotiateLoaderRuntimeInterface`. The runtime implements strict negotiation,
layer enumeration, a bounded instance lifecycle, and identifying instance properties. It also
exposes one HMD system with a primary-stereo, opaque view configuration at a fixed prototype
1680×1760 per-eye size. It advertises orientation and position tracking capability; individual
location results become tracked only while fresh M4 pose state is connected.

`XR_KHR_D3D11_enable` is now capability-gated by an in-process feature-level-11.0
create/share/reopen/copy/readback test. It remains absent under the installed WhiskyWine 7.7 +
Apple D3DMetal path and is advertised under the pinned disposable Wine 11.10 + DXMT v0.80 path.
In that path the runtime returns the DXGI adapter LUID, validates the application's graphics
binding, creates/destroys a session, enumerates the CoreVideo-compatible BGRA color formats, and supports two per-eye
swapchains (up to four total), each with three
`D3D11_RESOURCE_MISC_SHARED_NTHANDLE` textures and independent acquire/wait/release state. It
also implements session events/control, CTS-shaped 72 Hz frame call ordering with an
absolute-deadline waitable-timer scheduler, and bounded
`VIEW`/`LOCAL` reference spaces. The official Khronos loader smoke exercises these lifecycles and
independently opens every texture's NT handle.

The `hello_xr` initialization surface is now implemented and covered by both Wine smokes:
bounded instance-scoped path atoms, action sets and typed actions with spec name validation,
exact suggested-binding allowlist validation for all nine OpenXR 1.0 core interaction profiles,
localized resolved-source names, interaction-profile events, action-set priority, one-shot session
attachment with post-attach immutability, action spaces, the to-string calls, and
`xrLocateSpace`/`xrLocateViews` with live ALVR HMD poses, correct VIEW/LOCAL composition, and
calibrated Quest IPD/asymmetric FOV; ±31.5 mm/symmetric 90° remains only the pre-calibration
fallback. Without a fresh control-channel pose,
tracking-dependent location flags are cleared. Because a headless session never reaches
`FOCUSED`, `xrSyncActions` returns `XR_SESSION_NOT_FOCUSED`, all action states stay inactive,
no sources can be localized until they are bound, and haptics validate without firing. A connected
Quest session stores and resolves Touch bindings, snapshots actions, locates grip spaces, and
forwards haptics as described in M4 below.

`xrEndFrame` now validates and accepts stereo projection layers — layer flags, space and
swapchain session ownership, per-view poses/FOV, in-bounds image rects, the 16-layer limit,
and a released image in every referenced swapchain. Quad layers are validated the same way and
accepted but not yet composed; extension layers are still rejected.
As of 2026-07-18 accepted layers ARE consumed: with the Basalt DXMT fork
(`runtime/dxmt-fork`, IOSurface-backed swapchain textures) and the control socket
(`runtime/pe/control.cpp`, protocol in `docs/DXMT-INTEROP.md` §4), every layered
`xrEndFrame` signals a per-frame `ID3D11Fence` and a waiter thread hands the released
images' IOSurfaceIDs to the native side only after the fence completes. Connected sessions
report `shouldRender` true, progress `SYNCHRONIZED→VISIBLE→FOCUSED`, and let
`xrSyncActions`/haptics consume live Touch state; headless sessions behave
exactly as before. `test-dxmt.zsh` gates a 21-frame hello_xr-shaped stereo render loop
whose per-frame clear colors a native daemon verifies byte-exact per fence-confirmed
frame, and the Swift streamer's `RuntimeLink` selftest encoded the same runtime frames to
H.264 via zero-copy IOSurface → CVPixelBuffer → VideoToolbox. `RuntimeLink` is now plugged
into the same ALVR router as desktop capture, and `runtime/scripts/test-headset.zsh` drives a
long visual OpenXR producer through the complete wired Quest path. The runtime is still not
conformant or game-ready because remaining input edge cases and game setup are manual, but the
M3 graphics boundary is built, machine-verified, and visibly testable on-headset.

### M4 — Input, tracking, haptics ✅
Map ALVR tracking packets to OpenXR spaces (head/aim/grip), controller state to the OpenXR
action system, haptic actions back to ALVR. Add pose prediction (ALVR sends motion vectors +
timestamps). Acceptance: a real external OpenXR application completes a tracked D3D11 session,
and a live Quest gate physically verifies fused, world-fixed stereo, controller response, and
haptics over the complete transport path.

The first M4 slice is complete: protocol v2 adds daemon→runtime `HEAD_POSE`, with one PE receive
thread demultiplexing asynchronous tracking from swapchain acknowledgements. The Swift bridge
normalizes ALVR's OpenXR-native quaternion and coalesces samples; the runtime stores local receipt
time for freshness, advertises HMD tracking capability, and composes live LOCAL-from-HEAD through
`xrLocateViews` and mixed VIEW/LOCAL `xrLocateSpace` queries. Fresh samples set VALID+TRACKED;
missing/stale samples clear tracking-dependent flags. A synthetic interleaving test and a live
Quest run both pass. ALVR v20.14 already pre-predicts the head pose and zeros head velocities, so
additional extrapolation is intentionally deferred until the Quest/runtime clock domains are
mapped.

The first live head sample also establishes a gravity-aligned LOCAL origin at the current X/Z and
yaw. Holding the right Quest system/Meta button for 600 ms recenters that origin and queues the
core OpenXR LOCAL reference-space-change event. `changeTime` follows the latest predicted display
time already returned by `xrWaitFrame`, and the runtime retains the previous transform for lookups
before it, so an in-flight frame cannot jump into the new coordinate definition.

The second M4 slice advances the control channel through protocol v7. ALVR's corrected Touch grip
motions and velocities, sparse button deltas, active profile packets, calibrated views, and an
authoritative timestamped `ControllerMask` flow into an atomic
runtime input snapshot. Oculus Touch suggestions are stored and resolved at `xrSyncActions`;
boolean, float, vector, and pose states remain frozen until the next sync, with change flags and
runtime-local change times. All nine core profiles use exact user/component allowlists. Resolved
Touch sources have localized names and profile-change events; core action-set priority suppresses
lower-priority collisions consistently across action state, spaces, enumeration, and haptics.
Grip action spaces compose against LOCAL/VIEW (and may be an `xrLocateViews` base), chained
`XrSpaceVelocity` reports ALVR's supplied linear/angular velocity, and vibration actions return as
ALVR stream-ID-1 haptics over the same serialized socket as video. ALVR already predicts the
corrected grip pose, so the runtime does not extrapolate it a second time. Stock ALVR does not
transmit its separately-polled aim pose, making aim an intentional grip alias until upstream adds
distinct aim motion. Controller traffic is fair per hand, button state is bounded and
flow-controlled, a missing-hand mask immediately clears pose/velocity, and newer presence/motion
recovers tracking. ALVR control disconnect atomically resets all retained input. Existing action
spaces retain their backing resources when public action handles are destroyed. Calibrated Quest
IPD and asymmetric per-eye FOV now drive `xrLocateViews`; the headset visual gate renders a LOCAL-fixed depth
constellation and a physically scaled controller marker to expose stereo/head-tracking errors.
Each submitted frame also carries the exact Quest tracking timestamp consumed by its successful
`xrLocateViews` call through the control daemon and VideoToolbox to ALVR, preventing the client
from applying a newer or older pose to that rendered image.
The swapchain API deliberately rejects `arraySize=2` texture arrays because the native handoff
currently consumes one IOSurface per eye; Unity-style engines can then take their multipass
`arraySize=1` fallback rather than receiving a falsely supported multiview path. Khronos' real
`hello_xr` D3D11 application is built from pinned official 1.1.61 source as an external gate. It
now completes a live Quest run through `FOCUSED`, two eye swapchains, localized Touch actions,
roughly 14 seconds of rendering, and clean `STOPPING→IDLE→EXITING` teardown. User confirmation of
the live Quest gate now verifies fused, level/world-fixed visuals, 6DoF controller response, analog
squeeze, and squeeze-triggered haptics at 72 fps. M4 is complete.

### M5 — Wine bottle tooling ✅
The `basaltctl` Swift CLI creates and lists managed bottles, discovers pinned Wine,
WhiskyWine, and GPTK providers, and stores direct/Steam/BSManager/itch launch profiles. The VR
path APFS-clones the pinned Wine 11.10 engine per bottle before installing the Basalt DXMT fork;
shared Whisky/GPTK engines may back managed prefixes but are never patched. It stages the runtime
DLL and manifest at `C:\basalt\runtime`, registers `ActiveRuntime` under the Khronos HKLM key, and
verifies the exact bottle through the official loader. OpenComposite remains user-supplied:
installation is constrained to an `openvr_api.dll` inside the managed prefix, preserves the first
game DLL backup, and writes the D3D11 configuration beside it. A disposable end-to-end bottle and
all four launch-source profiles pass on Apple Silicon. See [BOTTLES.md](BOTTLES.md).

### M6 — Audio + USB ✅
USB streaming uses ALVR's native wired design: ADB forwards the Mac's localhost 9943/9944 to the
Quest listeners, ALVR switches stream traffic from UDP to TCP, and clean shutdown removes both
forwards. The audio path selects one explicit CoreAudio input (normally BlackHole 2ch), requests
48 kHz interleaved stereo PCM16, and packetizes the headerless samples on ALVR stream ID 2. Audio
uses an independent packet-index sequence and a one-block pending bound, so it cannot grow a
latency queue behind video. A device-local 440 Hz loopback gate verifies non-silent BlackHole
capture; the live Quest USB gate sustained 1.536 Mbps PCM with zero drops while video remained
near 72 fps, and the generated tone was confirmed audible through the Quest 3 speakers.
Manager launches temporarily route default application output into the selected loopback and
restore the prior output on teardown. Microphone backhaul remains future work, not part of M6.

### M7 — Management app
SwiftUI: setup wizard (permission checks, dependency install), bottle manager UI, game
library with auto-detection, stream dashboard (bitrate/latency/fps graphs, like MoltenVR's
"live stats"). The initial implementation is now in the `BasaltVR` Swift package executable:
it reuses `BasaltBottleKit`, discovers Basalt/Whisky/CrossOver prefixes, parses Steam VDF and app
manifests (including additional library folders), turns installed games into editable profiles,
starts and owns wired or Wi-Fi streamer plus Wine game processes, and parses the existing
two-second transport/Quest reports into bounded live chart history. Setup checks cover Apple
Silicon/macOS, Screen Recording, adb, the pinned Wine/DXMT artifacts, the OpenXR runtime, and
optional BlackHole audio. Global and per-profile stream settings persist through `UserDefaults`;
audio-enabled launches route output to the loopback for the owned session and restore it afterward.
The Basalt data root is user-selectable. External prefixes remain read-only, with an explicit
APFS-cloned import into an isolated pinned engine when a user wants VR support. An ad-hoc-signed
developer-preview bundle is reproducibly packaged with its permission descriptions and Basalt
runtime artifacts. M7 remains in progress until dependency provisioning is a supported end-user
flow, the app is Developer ID-signed and notarized, setup is exercised from a clean Mac user
account, and a managed Beat Saber launch completes the live Quest acceptance path from the GUI.

## Risks / open questions

- **DXMT interop** was the hardest initial unknown: exporting a D3D11 render target as
  an IOSurface-backed MTLTexture cleanly per swapchain image. A July 2026 audit of DXMT main
  (`73d42c55`) found working internal D3D11 NT-handle sharing through
  `MTLSharedTextureHandle` and Mach ports, but no supported texture-to-native-Metal COM API;
  keyed-mutex/shared-event synchronization is also incomplete. `runtime/scripts/test-dxmt.zsh`
  pins and verifies Wine 11.10 plus DXMT v0.80; its standalone probe and OpenXR swapchain smoke
  both pass create/reopen validation on the M3 Max. The installed WhiskyWine 7.7 + Apple D3DMetal
  path fails before sharing at `IDXGIResource1`, so the runtime hides the extension there.
  A July 2026 follow-up audit of DXMT `73d42c55` mapped the exact patch surface, and
  `docs/DXMT-INTEROP.md` now defines the fork scope, IOSurfaceID handoff, fence-based
  frame-completion signal, and control-socket protocol. The Phase-1 fence mechanism
  (`ID3D11Fence` signal → `SetEventOnCompletion` wait) and shared-fence creation are now
  probe-verified under the pinned stack by `dxmt_fence_probe` in `test-dxmt.zsh`. As of
  2026-07-18 the fork itself is implemented: `v0.80-basalt.1` (MIT v0.80 base;
  `runtime/dxmt-fork` + `runtime/scripts/build-dxmt-fork.zsh`) makes gated NT-handle
  shared textures IOSurface-backed and republishes per-image IOSurfaceIDs, validated
  end-to-end on loader-created OpenXR swapchain images by `test-dxmt.zsh`'s fork phase.
  The cross-process zero-copy proof also passes: a native process reads back, byte for
  byte, a fence-confirmed pattern D3D11 rendered under Wine, via the IOSurfaceID alone.
  `FrameReady`, the control socket, Swift consumption, and the wired-headset visual path are
  implemented; the remaining interop risk is the storage-mode performance comparison. Note:
  DXMT relicensed MIT → LGPL 2.1+
  after v0.80, which drives the fork-base decision recorded there.
- **ALVR protocol drift**: the client updates; pin to one client release (v20.14.0 like
  MoltenVR does) until the bridge is stable.
- **OpenXR conformance**: we only need "enough" conformance for Unity/UE/OpenComposite —
  full CTS conformance is a non-goal early on.
- **Latency budget**: 72 fps ⇒ ~14 ms/frame. The initial wired desktop prototype measured
  local capture→encode around 9–16 ms average and Quest-reported input→display around 53–62 ms
  average, with large occasional spikes. Decoder and vsync work dominate the current steady-state
  result. A controlled low-latency-preset sample reduced the decoder queue from roughly 10–12 ms
  to 3–4 ms and total reported latency from roughly 55–58 ms to 47–51 ms without losing the
  approximately 72 fps cadence. The M3 runtime originally restarted a rounded millisecond sleep
  after each late wake and therefore delivered only about 60 fps; its absolute-deadline scheduler
  now measures 71.96 fps under the pinned Wine stack and delivered 72.0 fps to the Quest in the
  visible integration gate on 2026-07-21 (roughly 49–50 ms average input→display). The
  user-selected quality-focused baseline is now wired, 72 fps, 1344×1408 per eye, 30 Mbps, and
  low latency. Game-texture handoff, pacing, encoder settings, compositor behavior, subjective
  head-motion quality, and sustained thermal behavior still need testing, with one setting
  varied per comparison.
- **Quest thermal state**: repeated high-resolution prototype sessions triggered Horizon OS thermal
  governance and MediaCodec buffer discards during testing. Performance comparisons must start from
  a cool headset; fixed user-selected settings and bounded queues do not replace foveated encoding.
- **Licensing**: keep GPLv3 OpenComposite an external artifact; everything first-party MIT.
