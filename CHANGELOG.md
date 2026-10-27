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
- Control protocol v11 and Quest optical hand tracking (off by default, opt-in). A
  hand without a controller drives an emulated Touch controller through ALVR's gestures (pinch =
  trigger, fist = grip, other pinches = face buttons), and games get the hand skeleton through
  the new runtime extension `XR_EXT_hand_tracking`. See `docs/HAND-TRACKING.md`.
- HEVC video (`--codec h264|hevc`, default `h264`): HEVC Main on the hardware encoder, sent with
  VPS/SPS/PPS and a `DecoderConfig` packet as ALVR's own servers send it.
  `basalt-streamer encoder-bench` measures encode time and drops for both codecs.
- OpenVR games through a locally built OpenComposite: `runtime/scripts/build-opencomposite.zsh`
  builds pinned upstream OpenComposite with Basalt's patches 0001–0005 (MinGW D3D11 build, MSVC
  struct-return ABI, `GetPosesForFrame`, `GetD3D9AdapterIndex`, legacy frame timing), and
  `runtime/openvr-proxy` provides an `openvr_api.dll` proxy for Valve-only exports.
  `basaltctl opencomposite install` gains `--proxy`, `--preset default|alyx`, and `--ini`, and
  writes only options OpenComposite can parse. See `docs/OPENCOMPOSITE.md`.
- Runtime: `STAGE` reference space, `XR_KHR_visibility_mask`, action sets attached again to a
  restarted session, quad layers, and a runtime compositor that converts non-BGRA, mipmapped,
  or oversized swapchains and flipped rects into a BGRA output; up to 16 swapchains.
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
- `basaltctl steam start PROFILE`.
- Runtime diagnostics: `BASALT_RUNTIME_LOG` (a log file, for games started by other programs),
  `BASALT_HAPTIC_LOG=1`, and `BASALT_COMPOSITOR_LOG=1` (the compositor's periodic debug readback,
  which runs only with it).
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
- **Add Game…** in the Library toolbar makes a launch profile for a Windows game from GOG, itch.io,
  or any installer, without `basaltctl profile add`. Choose a bottle and the game's `.exe` in its
  `drive_c`; the name comes from the game folder, itch.io is detected from the path, and the
  game folder becomes the profile's working directory and `gameRoot`. Profile names now fold
  accents and drop other non-ASCII letters, so `basaltctl` accepts every name the app creates.
- **Prepare VR** in the app (Add Game's **Add & Prepare VR**, a game tile's ⋯ menu, and the
  profile editor): finds whether a game is Half-Life: Alyx, OpenVR, or native OpenXR from its
  executable's PE imports and Unity plugin folder, asks for a VR mode when unsure, and installs
  the locally built OpenComposite (plus the OpenVR proxy, the `alyx` preset, and `-vr -dx11` for
  Alyx). It never downloads OpenComposite and names the build command when a build is missing.
  It keeps the first original DLL, refuses to replace files it did not write unless asked (then
  keeps a copy), rolls back on failure, stays inside the bottle without following links, and
  records hashes in `VRSetup/<profile>.json`. The status is re-checked on every refresh, so a
  Steam update that restores Valve's DLL shows **VR FILES CHANGED**. **Restore Game Files…**
  undoes the setup. "Setup ready" only means the files are in place. See `docs/MANAGEMENT.md`.
- Prepare VR is clearly source-checkout-only for OpenVR games and Half-Life: Alyx. A release
  bundle does not include OpenComposite (GPLv3), so the sheet says so up front, keeps Prepare VR
  disabled, and explains how to build OpenComposite in a source checkout. Native OpenXR setup and
  **Restore Game Files…** still work there.
- After a game update replaces the `openvr_api.dll` Basalt installed, Restore keeps the new DLL
  and retires the old `openvr_api.dll.basalt-original` (removed only when an identical copy is
  kept, otherwise renamed to `.basalt-stale-original-<time>`). Prepare VR also takes such a newer
  DLL as the original. A later Restore no longer writes the old DLL over the updated game.
- Deleting a profile with VR files offers **Restore and Delete** or **Delete Only**, and always
  removes its `VRSetup/<profile>.json` record, so a new profile with the same name no longer
  inherits the old setup.
- Prepare VR skips `openvr_api.dll` copies for another architecture (such as a 32-bit copy in
  Unity's `Plugins/x86`), leaves them unchanged, and lists them, instead of stopping the whole
  setup. It stops only when no copy matches the OpenComposite build.

### Changed

- `basaltctl opencomposite install` and the profile editor's manual installer (now **Install a
  DLL by Hand…**) refuse to replace an `opencomposite.ini` that Basalt did not write, and refuse a
  target, backup, or ini that is a symbolic link.
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
- Projection frames in exported BGRA swapchains (`B8G8R8A8_UNORM`, `_UNORM_SRGB`, or
  `B8G8R8A8_TYPELESS`) with one mip, at most twice the per-view size, and positive image rects go
  zero-copy; the streamer crops each eye by its `imageRect`, so UE4's side-by-side image skips the
  runtime compositor. Quad layers, flipped rects, other formats, mip chains, depth, and larger
  images still go through it.
- `runtime/scripts/build-opencomposite.zsh` clones upstream OpenComposite
  (<https://gitlab.com/znixian/OpenOVR> at `cff07db`) and applies the six commits of the former
  GitHub fork as patches, then Basalt's own, instead of cloning the fork.
- Hand tracking (`XR_EXT_hand_tracking`) is off by default; `--hand-tracking on` turns it on. The
  ALVR client's SteamVR grip offset is kept by default; `--grip-pose meta` removes it.
- The Basalt DXMT fork is tagged `v0.80-basalt.2` (patches 0005 and 0006). Nothing checks the DXMT
  version already in a bottle; run `basaltctl bottle install-dxmt <bottle>` after rebuilding, or 8x
  MSAA games stay black.

### Fixed

- Reinstalling the Steam UI compatibility launcher after a rebuild no longer overwrites Steam's
  preserved web helper with an older launcher build, which made the helper relaunch itself.
- A bottle whose creation or import fails is removed instead of being left half-made with its
  name taken.
- Quitting after closing the window now still stops the game, Steam, and the bottle's Wine
  processes. Stop no longer freezes the window while Wine shuts down; the next launch waits for it.
- The session log keeps each process's stdout and stderr lines whole and in order, and prefixes
  every Steam/game line rather than only the first line of each chunk.
- Diagnostic reports no longer include audio device names (only BlackHole or another device) or
  `[U:1:…]` Steam IDs.
- The OpenXR runtime now samples the head once per frame. For one `xrWaitFrame` display time,
  the first `xrLocateViews` or `xrLocateSpace` pins the newest head sample, and every later head
  query for that time returns the same pose. The frame goes to the streamer with that sample's
  timestamp. Before, OpenComposite games (Half-Life: Alyx) located each frame several times, each
  call got a newer sample (head poses arrive at about 216 Hz), and the last call set the frame's
  timestamp. The game rendered with an older pose than the timestamp named, so ALVR reprojected
  from the wrong pose and the world wobbled a little all the time. hello_xr locates once per
  frame and was not affected. With `BASALT_RUNTIME_LOG` set, the runtime log prints a
  `head pose pinning:` line every 5 s: the number of frames where a later head query saw a newer
  sample (these frames had the wrong timestamp before this fix).
- A slow game (The Lab's Secret Shop) or any hitch over 0.5 s no longer flickers between the game
  image and black.
- Touch controller poses can drop the ALVR client's SteamVR-only grip offset (-15° pitch, 5 mm),
  which OpenComposite stacked with its own transform (opt-in; the offset is kept by default). A
  hand-tracked hand no longer uses its raw palm pose as a controller grip.
- Haptics: zero amplitude is a stop, durations of zero or less play a 5 ms pulse, and
  out-of-range values from OpenVR translation layers are normalized instead of failing.
- The runtime's control socket is no longer inherited by child processes, and a newer
  authenticated runtime connection replaces a stale one. The Lab's Robot Repair, started by the
  hub, previously ran headless with a black headset.
- A forced recovery IDR that VideoToolbox rate control dropped is requested again instead of lost.
- Game audio capture asks for Microphone access first and explains a denial, instead of
  capturing silence from BlackHole.
- `basaltctl opencomposite install` no longer writes `enableAudio`, which OpenComposite's `openxr`
  branch rejects.
- The `hello-xr` profile no longer quits after about 10 s without a frame when started from the
  app. Khronos hello_xr quits at end of file on stdin, and the game got `/dev/null`. The game now
  gets an empty pipe as stdin that stays open until it exits (`HeldOpenStandardInput` in
  BasaltBottleKit, used by app sessions and `basaltctl run`).
- The streamer prints the Screen Recording hint only after a screen-capture error, not after every
  fatal error (an adb error got it too).
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
- The runtime advertises and accepts `LOCAL_FLOOR` and `STAGE` reference spaces, and only `VIEW`
  follows the head. Previously a VIEW-relative query against a floor space returned a constant
  pose, so OpenVR titles using a standing space rendered a frozen camera.
- An action set can be attached to a new session after its previous session is destroyed
  (OpenComposite rebuilds its session and re-attaches); it stays immutable.
- Swapchains may be up to twice the per-eye maximum width and height, so a side-by-side image with
  both eyes (UE4) is accepted, and `DXGI_FORMAT_B8G8R8A8_TYPELESS` is accepted as BGRA.
- Runtime stereo composition honours each eye's `imageRect`; side-by-side submissions no longer
  show the whole image squeezed into each eye.
- `xrGetReferenceSpaceBoundsRect` reports unavailable bounds for STAGE and LOCAL_FLOOR instead
  of rejecting them, which made OpenComposite abort at startup.
- Controller velocity is reported against LOCAL_FLOOR and STAGE, not only LOCAL.
- `xrEndFrame` accepts (validated) quad layers instead of failing the whole frame; quads are not
  yet composed, and the frame's projection layer is still streamed.
- After the headset reconnects with a restarted clock, head tracking resumes instead of
  dropping every pose whose timestamp is lower than the previous session's.
- Recentering also queues reference-space-change events for existing STAGE and LOCAL_FLOOR
  spaces; a full event queue never drops session-state changes and reports
  `XrEventDataEventsLost`; swapchain wait/release follow acquire order.
- Stopping the streamer during the USB headset handshake, or a failed start, now restores the Mac
  audio output and removes the adb forwards instead of leaving them behind.
- A closed USB video stream no longer spins the streamer at 100% CPU.
- Out-of-range headset values (encoding gamma, latency statistics, IPD/FOV calibration, button
  path or controller profile 0) are ignored instead of crashing the streamer or making the runtime
  drop its control connection.
- A restarted OpenXR session can replace the runtime connection before the old one closes, and a
  connection that never sends its Hello is dropped after 5 seconds.
- `basaltctl run` no longer reads its own options from game arguments after `--`.

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
- `make check` checks whitespace in every commit since the merge base with `origin/main` (or the
  pull request's base), not only uncommitted edits, and syntax-checks the app launcher script.
- The release packager refuses an incomplete DXMT artifact set instead of shipping it as included,
  and the DXMT fork build rebuilds a patched checkout that sits on an outdated upstream commit.
- `test-dxmt.zsh` adds the runtime compositor, 8x MSAA, OpenComposite frame-timing, and
  hand-tracking checks; `runtime/scripts/test-openvr-proxy.zsh` tests the proxy.

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
