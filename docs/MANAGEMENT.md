# BasaltVR management app

The M7 developer-preview app is a native macOS SwiftUI executable in the existing `streamer` package.
It is intentionally a thin front end over `BasaltBottleKit` and `BasaltCore`: bottles, profiles,
stream settings, and safety validation have one implementation shared with the command-line tools.

## Build and run

From the main checkout (not a worktree):

```sh
make app        # build/BasaltVR.app, installed to ~/Applications/BasaltVR.app
```

Then open BasaltVR from Finder, Launchpad, or Spotlight, pick a game, and press Play.

`make app` (`packaging/build-app.zsh`) builds the release tools and a small bundle that holds
only the app's own binary. Its Info.plist key `BasaltRepoRoot` links it to the checkout it was
built from: the app runs that checkout's `scripts/play.zsh` with
`streamer/.build/release/basalt-streamer` and `basaltctl`, and the bottle gets that checkout's
OpenXR runtime and Steam web helper shim. Terminal and the app therefore use the same copies,
and two shims can never replace each other. Rebuilding the checkout (`make build`) updates what
the app runs. `packaging/build-app.zsh --no-install` skips the copy to `~/Applications`, and a
linked worktree is never installed there.

The bundle is ad-hoc signed with the hardened runtime and
`com.apple.security.device.audio-input` (`packaging/BasaltVR.entitlements`), and Info.plist has
`NSMicrophoneUsageDescription`. macOS treats BlackHole as a microphone, and a command-line tool
uses the Microphone permission of the app that started it. The streamer runs as a child of
BasaltVR, so the prompt names BasaltVR and the permission belongs to it. Check the signature:

```sh
codesign -d --entitlements - ~/Applications/BasaltVR.app   # shows com.apple.security.device.audio-input
codesign -dv ~/Applications/BasaltVR.app 2>&1 | grep flags  # flags=0x10002(adhoc,runtime)
```

An ad-hoc signature changes with every build, so macOS can ask for Microphone access again after
`make app`. No Gatekeeper or SIP change is needed: the app is built on this Mac.

Run the app from source without a bundle (Microphone permission then belongs to the terminal):

```sh
make run-app    # swift run -c release --arch arm64 --package-path streamer BasaltVR
```

The release configuration keeps the SwiftUI manager responsive and optimizes the streaming hot
paths. The app launches the already-built `basalt-streamer` executable directly so it can own its
lifecycle and capture its live output; it does not start a second Swift build while a game session
is connecting. Set
`BASALT_REPO_ROOT` if the app is launched with neither the repository nor one of its descendants as
the working directory.

## Play (the start page)

The window opens on **Play** (on **Setup** only when required checks fail and no game profile
exists yet). Sections are also on ⌘1–⌘6, ⌘R rescans, ⌘. stops the active session, and the
sidebar footer always shows the session state with a Stop button.

- **Games**: one tile per launch profile (the plain `steam` sign-in profile is hidden), named and
  drawn from the Steam library cache of its bottle (`appcache/librarycache/<appid>`). The Lab and
  Beat Saber carry a VERIFIED badge and come first; The Lab is chosen by default. Click to
  choose, double-click to play.
- **Play** runs `scripts/play.zsh` for the chosen profile as a child of the app, so the app and
  Terminal share one launch flow: pick the Quest (USB wins; else Wi-Fi, after `adb connect` to the
  saved Quest IP), restart ALVR, start the streamer with BlackHole audio routed, start Steam with
  the web helper shim, run the game, follow its child programs (The Lab → Robot Repair), and save
  the Quest log (capped at 200 MB).
- **Connection**: Automatic (default; USB when the cable is in), USB cable, or Wi-Fi.
  **Quality**: High (default: `--quality high --codec hevc`; USB 1344×1408 at 60 Mbps, Wi-Fi
  1344×1408 at 50 Mbps, both verified with The Lab) or Normal (`--quality normal`; USB 30 Mbps
  HEVC, Wi-Fi 20 Mbps H.264 for slower Wi-Fi). Shell variables such as `BASALT_WIFI_MBPS` cannot
  override the app's choice.
- **Status** is one plain sentence from play.zsh's `@@basalt` events and the streamer log:
  "Looking for your Quest…", "Getting ALVR ready on your Quest…", "Put on your headset",
  "Starting The Lab…", "Playing The Lab", "Quest disconnected — reconnecting…", "Stopping…",
  "The game ended", or the reason it failed ("I cannot see your Quest on the USB cable. Plug it
  in, or choose Wi-Fi."). Live FPS on the Quest, delay (input to display), and Mbps come from the
  streamer's report lines.
- **Stop** sends SIGTERM to play.zsh, which runs the same cleanup as Ctrl-C: game, Steam and the
  bottle's Wine, streamer (Mac sound output restored), adb logcat. After 120 s the app kills
  play.zsh's process group. Quitting the app during a game first waits for this cleanup. If the
  app crashes, play.zsh notices (`BASALT_PLAY_PARENT_PID`) and cleans up by itself.
- **Before you play** checks, every 5 s while the page is open and no session runs
  (`scripts/quest-check.zsh`: one read-only look at adb; only the chosen Quest is asked for its
  ALVR version):
  - Quest found, waiting for "Allow USB debugging", or missing (Install Android Tools with
    Homebrew). With a USB Quest: **Use Without Cable** (`scripts/quest-wireless.zsh`: adb over
    Wi-Fi, IP saved). Without one but with a saved IP: **Reconnect over Wi-Fi**.
  - ALVR 20.14.1 on the Quest: **Install ALVR** (`install-quest-client.zsh --download`: downloads
    the release APK if needed and installs it only if its SHA-256 matches), or **Replace ALVR…**
    after a confirmation when another version is installed.
  - BlackHole 2ch: **Install BlackHole…** opens Terminal with `brew install --cask
    blackhole-2ch`, because the cask needs the Mac password; **Copy Command** copies it. A rate
    other than 48 kHz offers Audio MIDI Setup.
  - Microphone permission: **Allow Microphone…** shows the macOS prompt; if it was denied, the
    button opens Privacy & Security › Microphone.
- **Details** shows the last 400 lines of play.zsh output, Copy, Open Logs Folder
  (`~/Library/Logs/BasaltVR`), and the Quest log switch.

The Play session and the Stream page's session exclude each other.

## Library, Stream, and the rest

1. **Setup** checks Apple Silicon and macOS 14, adb, the pinned Wine/DXMT engine, the built OpenXR
   runtime, optional Screen Recording permission, and optional BlackHole audio. The adb and
   BlackHole actions use an existing Homebrew installation. Build-related actions open the M5
   instructions because compiling the pinned runtime is still a developer operation.
2. **Bottles** shows Basalt-managed prefixes alongside installed Whisky and CrossOver bottles.
   External prefixes are read-only. **Copy into Basalt** creates an isolated pinned-engine bottle,
   APFS-clones the existing prefix without changing its source, and runs Wine's prefix update.
   Prepare then installs DXMT and OpenXR and runs the same loader verification as
   `basaltctl bottle prepare`. Managed bottles can launch Steam or a selected Windows installer.
   **New Bottle** (⇧⌘N) creates an empty bottle on a chosen engine.
3. **Library** parses Steam `libraryfolders.vdf` and installed `appmanifest_*.acf` files in
   every discovered bottle, follows mapped extra Steam-library drives, and uses local Steam artwork
   where available. It also discovers BSManager versions below the default
   `~/BSManager/BSInstances`, the legacy Documents location, BSManager's configured installation
   parent, managed bottles, or a folder selected with **Locate Instances Folder**. The BSManager
   section detects its standard Windows installation inside every Basalt bottle, launches it with
   that bottle's Wine environment, and can run an official Windows installer for installation or
   updates. Versions BSManager creates inside a bottle are picked up automatically after it exits.
   Each external instance remains read-only and can become a profile in a selected Basalt bottle
   with the Steam identity and BSIPA `winhttp` override already set. Toolbar search plus VR-only and tool
   filters are included; playable games sort first in each section. Existing profiles and direct Beat Saber detections appear alongside Steam
   and BSManager games. Steam games in a managed bottle can become `-applaunch APP_ID` profiles
   without re-entering paths.
4. **Profiles** can edit their source, Windows executable, working directory, arguments, and
   environment, or be deleted without removing the game. OpenComposite installation is available
   from the profile editor while keeping the separately supplied DLL inside the managed prefix.
5. **Play** (from a game tile, or the Stream page's game picker) starts wired or Wi-Fi ALVR with the selected FPS, bitrate, resolution, latency preset,
   and optional audio input. When audio is enabled, the streamer temporarily routes default
   application output to that loopback and restores the prior output on shutdown. Once the
   authenticated runtime control file exists, the app asks `BasaltBottleKit` for a fully validated
   Wine launch command and owns that child process too.
6. **Stream** shows the session state, the effective stream settings for the selected game, the
   latest Quest FPS, actual wire Mbps, and input-to-display latency with bounded sparkline history
   and average/min/max, and the raw session log (copyable, and clearable between sessions). Stopping the session terminates both children;
   an unexpected streamer exit also terminates the game. While streaming, a health banner explains
   a headset that stopped reporting frames, a sustained frame rate below 90% of the target, latency
   above the latency preset's budget, thermal pressure, or Low Power Mode, with a settings
   suggestion for the next session. **Save** writes the log, or every metric sample of the session
   as CSV for comparing runs.
7. **Recent Sessions** (on the Stream page) records each session's game, settings, streamed
   duration, outcome (ended, stopped, or the failure reason), and whole-session FPS, latency, and
   wire-rate averages, including how often the headset ran below its target. The last 50 sessions
   are kept in `SessionHistory.json` in the data folder; a finished game can be replayed from its row.
8. **Settings** persists global stream defaults and per-profile overrides, selects audio and
   USB/Wi-Fi transport, and allows the managed Basalt data directory to be changed from the UI.
9. **Diagnostic Report** (Settings, or **Help › Diagnostic Report…**) previews a bug-report
   snapshot: app version, commit, and control protocol; Mac model, macOS, and power state; setup
   checks; engines, bottles, and profiles; stream settings; the current and recent sessions; and,
   optionally, the end of the session log. It can be copied as Markdown for a GitHub issue or saved
   as Markdown or JSON. The home folder and user name, email addresses, Steam IDs, headset serials
   and host names, Mac host names, IP and MAC addresses, and long hex tokens are replaced before
   anything is shown, and profile environment values are never included. Nothing is uploaded.

Generic non-Steam executable scanning outside managed prefixes, online metadata/artwork, a
Developer ID-signed and notarized `.app` bundle, and a clean-user-account/live-Quest acceptance
run remain for later M7 work.
OpenComposite continues to be user-supplied and is never downloaded or redistributed by this app.

The GitHub developer-preview archive contains an ad-hoc-signed app, not a notarized consumer
installer. It does not bundle third-party Wine binaries. Developers can create a local preview
archive with:

```sh
packaging/build-release.zsh 0.1.0
```

The packager includes Basalt runtime and DXMT artifacts when they exist in the ignored build tree,
and records exactly what was included in the archive.

## Tests

```sh
swift test --package-path streamer
```

`BasaltManagerKitTests` covers the Play page: play.zsh arguments and environment for every
connection × quality, `@@basalt` event parsing, the status state machine (disconnects, Stop,
failures, crashes), live stats, game tiles and artwork matching, Quest status parsing, the
first-run checks and their fixes, and the bundle environment. `PlaySessionRunnerTests` runs the
real `scripts/play.zsh` with a fake adb, streamer, basaltctl, and steam.zsh: a full session, the
streamer arguments for every connection × quality, a missing USB Quest, and Stop during a game
(game, streamer, Steam, and logcat all end). `scripts/test-quest-adb.zsh` (part of `make check`)
covers the same scripts from the shell side: the events, the saved-IP reconnect, the app-gone
cleanup, `quest-check.zsh`, and the ALVR download SHA check.
It also covers external-bottle metadata, Steam VDF/manifests, artwork, BSManager
default/configured/explicit-location and managed-bottle launcher/instance discovery, Windows/host
path mapping, Beat Saber scanning and source inference, duplicate resolution, stream argument
generation, live-stat parsing, session history persistence and summaries, stream-health rules,
metric CSV export, diagnostic redaction, and report rendering. `BasaltBottleKitTests` verifies repository/support-root
discovery, maintenance and VR launch commands, the BSManager Steam prerequisite, profile deletion,
and a real isolated import whose source remains unchanged.
