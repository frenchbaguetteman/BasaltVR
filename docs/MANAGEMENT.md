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
   it first with Bottles → ⋯ → Run Windows Installer…). The name comes from the game folder and
   the source (Direct or itch.io) from the path; optional arguments are split on spaces, without
   quotes. The game folder becomes the working directory and the profile's game folder
   (`gameRoot`). Once the `.exe` is chosen, the sheet looks for the game's VR files (see
   **Prepare VR** below) and offers **Add & Prepare VR**; **Add Only** adds the profile without
   changing any game file. It is the same profile as `basaltctl profile add`.
4. **Prepare VR…** (a game tile's ⋯ menu, or the profile editor's VR Setup section) sets a game
   up for Basalt's OpenXR runtime with the same steps Add & Prepare VR uses:
   - *Detection* is conservative. Half-Life: Alyx is known by `hlvr.exe` or Steam app 546560. A
     game counts as OpenVR or native OpenXR only when its executable imports `openvr_api.dll` or
     `openxr_loader.dll` (read from the PE import table), or the DLL is in that Unity player's
     own `<Game>_Data/Plugins` folder. A DLL that only sits somewhere in the game folder, both
     kinds at once, or nothing at all makes the result uncertain; then **VR mode** (Auto /
     Native OpenXR / OpenVR (OpenComposite) / Half-Life: Alyx) must be chosen. The search does
     not follow symbolic links and stops after 40,000 entries.
   - *Native OpenXR* changes no game file.
   - *OpenVR* installs `runtime/build/opencomposite/out/openvr_api.dll` over each `openvr_api.dll`
     the executable loads (or, when OpenVR was chosen by hand, every `openvr_api.dll` in the game
     folder) and writes the `default` `opencomposite.ini`.
   - *Half-Life: Alyx* installs `runtime/build/openvr-proxy/bin/openvr_api.dll` as
     `game/bin/win64/openvr_api.dll` with OpenComposite beside it as
     `openvr_api_opencomposite.dll`, writes the `alyx` preset (`initUsingVulkan=false`,
     `invertUsingShaders=true`), adds `-vr -dx11` to the profile's arguments, and removes
     `-vulkan` and `hello_xr` test flags (`-g D3D11`, `-ff Hmd`, `-vc Stereo`, `-bm Opaque`,
     `--space Local`).
   - Basalt uses only these local builds and never downloads OpenComposite. When one is missing,
     the sheet names the command that builds it (`runtime/scripts/build-opencomposite.zsh`, or
     `runtime/scripts/test-openvr-proxy.zsh` for the proxy) and the checkout it runs in, and
     Prepare stays disabled. Both must be 64-bit PE DLLs. When a game has several
     `openvr_api.dll` copies, a copy for another architecture (such as a 32-bit one in Unity's
     `Plugins/x86`) is skipped, left unchanged, and listed in the result; the matching copies are
     set up. When no copy matches, Prepare stops with nothing changed and names each copy.
   - OpenVR and Alyx setup is source-checkout-only. OpenComposite is GPLv3, so the release bundle
     does not include it or the proxy. When the app runs from a release bundle (packaged support
     files instead of a source checkout), the sheet says so before a mode is chosen, Prepare VR
     stays disabled for OpenVR and Alyx, and the message says to build OpenComposite in a
     BasaltVR source checkout and start the app from there. Native OpenXR setup and **Restore
     Game Files…** need no build and work in every copy.
   - The game's `openvr_api.dll` is kept as `openvr_api.dll.basalt-original`. A later setup keeps
     that original while the game still has Basalt's DLL or the original. When the game's DLL
     changed after the original was kept (often a game update), that newer DLL becomes the
     original after **Replace and Keep Copies**, and the older original is kept: it is removed
     only when an identical `.basalt-replaced-…` copy exists, otherwise it is renamed to
     `openvr_api.dll.basalt-stale-original-<UTC time>`. Files Basalt did not write (including
     the game's first `openvr_api.dll`, a custom `openvr_api_opencomposite.dll`, or an edited
     `opencomposite.ini`) stop the setup with nothing changed. **Replace and Keep Copies** then
     saves each as `<name>.basalt-replaced-<UTC time>` before replacing it, with a numeric suffix
     when needed so earlier copies are never overwritten. Add Game asks in the same sheet;
     retrying uses the profile already added.
   - Every target must be inside the bottle's `drive_c` after resolving links, and Basalt does not
     replace a file that is itself a symbolic link. Folder links that stay inside `drive_c`
     are allowed. A failure part-way puts every touched file and the profile
     back. Repeating Prepare VR is safe; changing the mode or the target folders needs Restore
     first.
   - What was installed, with SHA-256 hashes, is recorded in `VRSetup/<profile>.json` in the data
     folder. The status ("Setup ready … files checked", or "Files changed since setup") is
     recomputed from the files on every Library refresh, so a Steam update or "Verify integrity
     of game files" that puts Valve's DLL back shows a **VR FILES CHANGED** chip and a Prepare
     VR… button beside Play. "Setup ready" means the files are in place, not that the game works;
     that needs a headset test.
   - **Restore Game Files…** puts the original DLL back, removes the files Basalt installed and
     its argument changes, and deletes the record. Files that changed after setup are left alone
     and listed, and the `.basalt-replaced-…` copies are kept. When a game update replaced
     Basalt's `openvr_api.dll`, Restore leaves the newer DLL and retires the old original in the
     same way (removed only when an identical copy is kept, otherwise renamed to
     `openvr_api.dll.basalt-stale-original-<UTC time>`), so the next Prepare VR takes the newer
     DLL as the original and a later Restore never puts the old one back. If the original DLL backup is
     missing, Restore keeps that folder's complete setup and record for a later retry and
     reports that restoration is incomplete. Unedited arguments return to their exact original order.
5. **Profiles** can edit their source, Windows executable, working directory, arguments, and
   environment, or be deleted without removing the game. When Prepare VR installed files for the
   profile, **Delete Profile…** offers **Restore and Delete** (puts the game's own files back
   first, and keeps the profile if that restore is not complete) or **Delete Only** (Basalt's
   files stay in the game folder). Deleting always removes `VRSetup/<profile>.json`, so a new
   profile with the same name starts with no VR setup.
   The profile editor keeps the advanced **Install a DLL by Hand…** installer, which writes a
   chosen DLL inside the managed prefix and refuses to replace an `opencomposite.ini` Basalt did
   not write.
6. **Play** (from a game tile, or the Stream page's game picker) starts wired or Wi-Fi ALVR with the selected FPS, bitrate, resolution, latency preset,
   and optional audio input. When audio is enabled, the streamer temporarily routes default
   application output to that loopback and restores the prior output on shutdown. Once the
   authenticated runtime control file exists, the app asks `BasaltBottleKit` for a fully validated
   Wine launch command and owns that child process too.
7. **Stream** shows the session state, the effective stream settings for the selected game, the
   latest Quest FPS, actual wire Mbps, and input-to-display latency with bounded sparkline history
   and average/min/max, and the raw session log (copyable, and clearable between sessions). Stopping the session terminates both children;
   an unexpected streamer exit also terminates the game. While streaming, a health banner explains
   a headset that stopped reporting frames, a sustained frame rate below 90% of the target, latency
   above the latency preset's budget, thermal pressure, or Low Power Mode, with a settings
   suggestion for the next session. **Save** writes the log, or every metric sample of the session
   as CSV for comparing runs.
8. **Recent Sessions** (on the Stream page) records each session's game, settings, streamed
   duration, outcome (ended, stopped, or the failure reason), and whole-session FPS, latency, and
   wire-rate averages, including how often the headset ran below its target. The last 50 sessions
   are kept in `SessionHistory.json` in the data folder; a finished game can be replayed from its row.
9. **Settings** persists global stream defaults and per-profile overrides, selects audio and
   USB/Wi-Fi transport, and allows the managed Basalt data directory to be changed from the UI.
10. **Diagnostic Report** (Settings, or **Help › Diagnostic Report…**) previews a bug-report
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
metric CSV export, diagnostic redaction, and report rendering. `VRSetupTests` covers VR setup:
PE import parsing, Alyx/OpenVR/OpenXR/uncertain detection (a nearby DLL alone is not enough,
links are not followed), the Alyx proxy, preset, and arguments, native OpenXR changing nothing,
missing builds and release bundles without OpenComposite, 32-bit and mixed-architecture DLLs,
repeat setup keeping the first backup, the status after a Steam-style
DLL restore, a game update between setup and Restore (the updated DLL is kept and the old
original retired), custom-file protection, replacement copies, restore, profile deletion with
and without Restore (the VR record always goes), rollback after a failure part-way, and paths
or links that leave the bottle. `BasaltBottleKitTests` also verifies repository/support-root
discovery, maintenance and VR launch commands, the BSManager Steam prerequisite, profile deletion,
and a real isolated import whose source remains unchanged.
