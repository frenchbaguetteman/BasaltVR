# BasaltVR management app

The M7 developer-preview app is a native macOS SwiftUI executable in the existing `streamer` package.
It is intentionally a thin front end over `BasaltBottleKit` and `BasaltCore`: bottles, profiles,
stream settings, and safety validation have one implementation shared with the command-line tools.

## Build and run

From the repository root:

```sh
swift build -c release --package-path streamer
swift run -c release --arch arm64 --package-path streamer BasaltVR
```

The release configuration keeps the SwiftUI manager responsive and optimizes the streaming hot
paths. The app launches the already-built `basalt-streamer` executable directly so it can own its
lifecycle and capture its live output; it does not start a second Swift build while a game session
is connecting. Set
`BASALT_REPO_ROOT` if the app is launched with neither the repository nor one of its descendants as
the working directory.

## Current workflow

The window opens on the **Library** once the required setup checks pass and on **Setup** until then.
Sections are also on ⌘1–⌘5, ⌘R rescans, ⌘. stops the active session, and the sidebar footer always
shows the session state with a Stop button.

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
   without re-entering paths. **Add Game…** (toolbar, `plus`) adds any other Windows game, such as
   one from GOG or itch.io: pick a Basalt bottle and the game's `.exe` inside its `drive_c` (install
   it first with Bottles → ⋯ → Run Windows Installer…). The name comes from the game folder,
   skipping build folders such as `Binaries/Win64` or `bin/win64`. The source is itch.io when a
   folder inside `drive_c` is named for it (the itch app's `itch\apps`, or `Itch Games`), else
   Direct. Optional arguments are split on spaces, without
   quotes. The game folder becomes the working directory and the profile's game folder
   (`gameRoot`). SteamVR games still need OpenComposite from the profile editor; native OpenXR
   games do not. It is the same profile as `basaltctl profile add`.
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

`BasaltManagerKitTests` covers external-bottle metadata, Steam VDF/manifests, artwork, BSManager
default/configured/explicit-location and managed-bottle launcher/instance discovery, Windows/host
path mapping, Beat Saber scanning and source inference, duplicate resolution, stream argument
generation, live-stat parsing, session history persistence and summaries, stream-health rules,
metric CSV export, diagnostic redaction, and report rendering. `BasaltBottleKitTests` verifies repository/support-root
discovery, maintenance and VR launch commands, the BSManager Steam prerequisite, profile deletion,
and a real isolated import whose source remains unchanged.
