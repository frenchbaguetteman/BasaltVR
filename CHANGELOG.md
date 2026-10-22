# Changelog

All notable changes to BasaltVR are documented here.

## Unreleased

Upgrade note: control protocol v10 and then v11 are breaking changes. The OpenXR runtime DLL in
each bottle and `basalt-streamer` must come from the same build; after updating, run
`make runtime-build` and `basaltctl bottle prepare <bottle>` (the management app syncs the DLL
before each session). The streamer reports a mismatched DLL instead of connecting.

### Added

- Control protocol v10: `HelloAck` carries the negotiated Quest refresh period, and `xrWaitFrame`
  paces to it instead of a fixed 72 Hz, so `--fps 90` or `--fps 120` with `--runtime` no longer
  renders 72 Hz frames for a faster display.
- Control protocol v11 and Quest optical hand tracking (`--hand-tracking on|off`, default on). A
  hand without a controller drives an emulated Touch controller through ALVR's gestures (pinch =
  trigger, fist = grip, other pinches = face buttons), and games get the hand skeleton through
  the new runtime extension `XR_EXT_hand_tracking`. See `docs/HAND-TRACKING.md`.
- HEVC video (`--codec h264|hevc`, default `h264`): HEVC Main on the hardware encoder, sent with
  VPS/SPS/PPS and a `DecoderConfig` packet as ALVR's own servers send it.
  `basalt-streamer encoder-bench` measures encode time and drops for both codecs.
- OpenVR games through a locally built OpenComposite: `runtime/scripts/build-opencomposite.zsh`
  builds a pinned OpenComposite fork with Basalt's patches 0001–0005 (MinGW D3D11 build, MSVC
  struct-return ABI, `GetPosesForFrame`, `GetD3D9AdapterIndex`, legacy frame timing), and
  `runtime/openvr-proxy` provides an `openvr_api.dll` proxy for Valve-only exports.
  `basaltctl opencomposite install` gains `--proxy`, `--preset default|alyx`, and `--ini`, and
  writes only options OpenComposite can parse. See `docs/OPENCOMPOSITE.md`.
- Runtime: `STAGE` reference space, `XR_KHR_visibility_mask`, action sets attached again to a
  restarted session, quad layers, and a runtime compositor that converts non-BGRA, mipmapped,
  or oversized swapchains, sub-rects, and flipped rects into a BGRA output; up to 16 swapchains.
- The streamer survives ALVR client disconnects over USB and Wi-Fi: it ends that session, sends
  `INPUT_RESET` to the runtime, and accepts the next connection while the game keeps running.
- Loss recovery: frames are not encoded while the transport is busy, and after a lost access
  unit P-frames are held until a forced IDR, so the Quest never decodes against a missing
  reference. The USB link rides out pauses of up to 5 s instead of dropping the headset.
- A timer-driven `pipeline` line every 2 s: tracking rate and gaps, runtime frames with untracked
  or repeated poses, encode time, per-stage drops, and pose age at send.
- `--profile m3pro`, `--idr-interval <seconds>`, `--entropy cabac|cavlc`, and
  `--controller-prediction full|alvr`; the startup log lists VideoToolbox properties that the
  encoder refused. See `docs/PERFORMANCE.md`.
- `basaltctl steam start PROFILE` and `basaltctl profile add --game-root PATH`.
- Scripts: `scripts/play.zsh` (one-command session over USB or Wi-Fi with `--quality`, `--codec`,
  and Quest log capture), `scripts/steam.zsh`, `scripts/install-quest-client.zsh`,
  `scripts/quest-wireless.zsh`, and the shared `quest-adb.zsh` and `game-processes.zsh` helpers.
- Runtime diagnostics: `BASALT_RUNTIME_LOG` (a log file, for games started by other programs) and
  `BASALT_HAPTIC_LOG=1`.
- Basalt DXMT fork patches 0005 (build with the Xcode 27 Metal toolchain) and 0006 (8x MSAA falls
  back to the largest supported sample count instead of failing).
- `docs/COMPATIBILITY.md`: The Lab verified on an M3 Pro with a Quest 3 over USB and Wi-Fi.
- Control protocol v9 (breaking: the bottle's runtime DLL and the streamer must match). The daemon
  acknowledges each frame with `FrameConsumed` after Metal has read its source surfaces, and the
  runtime holds `xrWaitFrame` to a two-frame window so latency cannot accumulate.
- The control file carries the selected per-eye stream size, which the runtime advertises as the
  recommended swapchain size instead of rendering 1680×1760 and downscaling.
- Holding the right Quest system/Meta button for 600 ms recenters LOCAL and queues
  `XrEventDataReferenceSpaceChangePending`. The initial LOCAL origin is now also yaw-leveled.
  The Quest OS may reserve this button; the gesture is not yet verified on hardware.
- `--latency ultra` / "Ultra Low": a one-frame decoder target with reduced smoothing history.
- Diagnostic reports (Settings, or Help › Diagnostic Report…): a reviewable snapshot of the app
  version and commit, control protocol, Mac and power state, setup checks, engines, bottles,
  profiles, stream settings, recent sessions, and optionally the session log, copied as Markdown
  for a GitHub issue or saved as Markdown/JSON. Home paths, user names, emails, Steam IDs, headset
  serials and host names, IP/MAC addresses, and tokens are redacted; nothing is uploaded.
- Session history: the Stream page lists recent sessions with streamed duration, outcome or failure
  reason, whole-session FPS/latency/wire-rate averages, and time below the target frame rate, with
  replay. The last 50 sessions are kept in `SessionHistory.json` in the data folder.
- A live stream-health banner flags a silent headset, a sustained frame rate below target, high
  latency for the selected preset, thermal pressure, and Low Power Mode, with a settings suggestion.
- The session log can be saved to a file, and every metric sample of a session exported as CSV.

### Changed

- Redesigned management app: lava-tinted native layout with a grouped sidebar (counts, setup
  badge, live session card with Stop), toolbar search and filters, one artwork tile style for
  Steam, BSManager, and profile games with hover-to-play, a Stream hero with the selected game and
  its effective settings, metric tiles with sparklines, grouped-form Setup/Bottles/Settings pages,
  a New Bottle sheet, and ⌘1–⌘5 / ⌘R / ⌘. shortcuts. Frame rate is now chosen from headset
  refresh rates and bitrate from a 10–200 Mbps slider; existing custom values are preserved. The
  manager source is split into one file per page.
- Runtime stereo composition is asynchronous and overlaps game rendering with encode.
- The manager stops stale Wine processes in the bottle and syncs the runtime DLL before each
  session, so a stale protocol version cannot connect headlessly. It re-registers the runtime (a
  Wine cold start) only when the bottle's registry no longer names it.
- `basalt-streamer --runtime` refuses a per-eye resolution above the runtime's 1680×1760 maximum
  instead of letting the game silently render at a different size than the stream.
- `make app` runs the release build.
- The stream configuration asks the ALVR client to predict controllers as far ahead as the head
  (`steamvr_pipeline_frames = 0`); with ALVR's default they lagged the head by 2–3 frames because
  Basalt does not extrapolate them as SteamVR does. `--controller-prediction alvr` restores it.
- The runtime advertises only BGRA swapchain formats, so engines that choose from the list stay on
  the zero-copy path; other formats are still accepted and converted by the compositor.
- While the game submits no frames, the streamer no longer sends black filler frames. ALVR keeps
  showing the last image; Basalt re-sends the last game image only when the headset does not have
  it, and sends black only before the first game frame of a session.
- The README is now a concise project overview; the streamer command-line guide (USB/Wi-Fi, audio,
  stream settings, measurements, and security model) moved to `docs/STREAMER.md`.

### Fixed

- The OpenXR runtime now samples the head once per frame. For one `xrWaitFrame` display time,
  the first `xrLocateViews` or `xrLocateSpace` pins the newest head sample, and every later head
  query for that time returns the same pose. The frame goes to the streamer with that sample's
  timestamp. Before, OpenComposite games (Half-Life: Alyx) located each frame several times, each
  call got a newer sample (head poses arrive at about 216 Hz), and the last call set the frame's
  timestamp. The game rendered with an older pose than the timestamp named, so ALVR reprojected
  from the wrong pose and the world wobbled a little all the time. hello_xr locates once per
  frame and was not affected. The runtime log prints a `head pose pinning:` line every 5 s: the
  number of frames where a later head query saw a newer sample (these frames had the wrong
  timestamp before this fix).
- A slow game (The Lab's Secret Shop) or any hitch over 0.5 s no longer flickers between the game
  image and black.
- Touch controller poses no longer carry the ALVR client's SteamVR-only grip offset (-15° pitch,
  5 mm), which OpenComposite stacked with its own transform. A hand-tracked hand no longer uses its
  raw palm pose as a controller grip.
- Haptics: zero amplitude is a stop, durations of zero or less play a 5 ms pulse, and
  out-of-range values from OpenVR translation layers are normalized instead of failing.
- The runtime's control socket is no longer inherited by child processes, and a newer
  authenticated runtime connection replaces a stale one. The Lab's Robot Repair, started by the
  hub, previously ran headless with a black headset.
- `scripts/play.zsh` no longer ends the session when the launched executable exits but the game
  goes on in another program from its install folder (The Lab's hub starts Robot Repair).
- A forced recovery IDR that VideoToolbox rate control dropped is requested again instead of lost.
- The Steam web helper shim is never preserved as Steam's original helper, which made the shim
  launch itself in a loop.
- Game audio capture asks for Microphone access first and explains a denial, instead of
  capturing silence from BlackHole.
- Quest adb selection: a USB Quest always wins, only Quest models are chosen, and a transient
  `adb devices` listing is retried.
- `basaltctl opencomposite install` no longer writes `enableAudio`, which OpenComposite's `openxr`
  branch rejects.
- Open BSManager now launches with `start /wait`. A bare `start` exited immediately, and the
  utility exit handler then stopped every Wine process in the bottle, closing BSManager before its
  window appeared.
- Bundled `basaltctl` now locates the app's packaged support files when invoked outside the source
  checkout.
- The wire-rate chart no longer picks up audio transport `Mbps` lines.
- A bottle with no running wineserver no longer blocks session launch.
- A late failure or cancelled receive from a replaced runtime connection no longer tears down
  the streamer's new connection.
- A runtime DLL built for another control protocol version is reported (streamer log and a
  manager alert, naming both versions) instead of silently leaving the headset black.
- `make release` rebuilds an existing `runtime/build` tree before packaging and rejects a
  non-Release tree, instead of bundling whatever DLL was last built (possibly an older control
  protocol than the freshly built streamer).
- Pressing Stop while a session is still starting now cancels the launch. Previously it could
  go on to start Steam, the streamer, and the game, report a spurious failure, or, after a
  delayed Steam sign-in timeout, tear down a session started afterwards.

### Project maintenance

- Added `runtime/CMakePresets.json` so IDE configures use the MinGW toolchain.
- A Swift test pins `RuntimeLink`'s protocol mirror to `basalt_control_protocol.h`.
- `make check` (and CI) compiles the native control daemon and IOSurface readback tools.
- The DXMT smoke no longer races the daemon's asynchronous post-Hello input injection.
- `test-dxmt.zsh` also runs the smoke against the production streamer's `RuntimeLink`, prints
  both sides of a failed control-socket run, and restores the stock overlay if the fork phase
  fails.
- Added one-command environment, test, build, documentation-link, and repository-hygiene checks.
- Added maintainer, support, triage, compatibility-report, and contributor workflows.
- Hardened GitHub Actions configuration and release preflight validation.
- `scripts/check.zsh` runs `scripts/test-quest-adb.zsh` (Quest serial choice and Quest log
  cleanup with a fake `adb`). `test-dxmt.zsh` adds the runtime compositor, 8x MSAA, OpenComposite
  frame-timing, and hand-tracking checks; `runtime/scripts/test-openvr-proxy.zsh` tests the proxy.

## 0.1.0 - 2026-07-28

Initial public developer preview.

- Native SwiftUI manager, streamer, and bottle/profile CLI.
- ALVR v20 wired and wireless video transport with optional BlackHole audio.
- Experimental Windows OpenXR runtime with D3D11/DXMT/IOSurface handoff.
- HMD and Touch tracking, OpenXR actions, controller presence, velocity, and haptics.
- Managed Wine bottle isolation, OpenXR registration, Steam launch profiles, and OpenComposite
  installation from a user-supplied artifact.
- Automated Swift, Wine loader, and DXMT acceptance coverage.

This is not a conformant OpenXR runtime or a general PCVR compatibility release.
