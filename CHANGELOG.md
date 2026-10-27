# Changelog

All notable changes to BasaltVR are documented here.

## Unreleased

### Added

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
- The README is now a concise project overview; the streamer command-line guide (USB/Wi-Fi, audio,
  stream settings, measurements, and security model) moved to `docs/STREAMER.md`.

### Fixed

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
