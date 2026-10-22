# Managed bottles and launch profiles

Milestone 5 is implemented by the `basaltctl` executable in the streamer's Swift package. Its
default data root is `~/Library/Application Support/BasaltVR`; set `BASALT_DATA_DIR` or pass
`--root PATH` to use a different root. Every writable bottle prefix, private engine, metadata
file, and launch profile stays below that root.

> [!IMPORTANT]
> The downloadable developer-preview app includes Basalt's compiled runtime and DXMT handoff
> artifacts, but it does not redistribute the pinned Wine engine. Creating the supported VR bottle
> currently requires a prepared source checkout and the build steps below. The packaged manager is
> not yet a turnkey installer.

## Engines and safety

Run the prerequisite check from the repository root:

```sh
swift run --package-path streamer basaltctl doctor
swift run --package-path streamer basaltctl engines
```

The supported VR provider is `pinned-wine-11.10-dxmt-0.80`. Creating one of these bottles uses
an APFS copy-on-write clone of the verified Wine toolchain, so installing the Basalt DXMT fork
cannot affect another bottle. Installed WhiskyWine and GPTK providers are also discoverable for
managed prefixes, but `bottle prepare` deliberately refuses to overlay DXMT into those shared
engines. CrossOver bottles and applications are never modified.

Bottle and profile names accept only 1–64 ASCII letters, digits, dots, underscores, and hyphens;
the first character must be alphanumeric. Loaded metadata is checked against its managed
directory. A pinned engine must remain inside its own bottle, while a shared provider must still
exactly match a currently discovered engine.

## Bottle commands

```sh
swift run --package-path streamer basaltctl bottle list
swift run --package-path streamer basaltctl bottle create beat-saber \
  --engine pinned-wine-11.10-dxmt-0.80
swift run --package-path streamer basaltctl bottle prepare beat-saber
swift run --package-path streamer basaltctl bottle verify beat-saber
```

`create` initializes a win64 prefix. `prepare` installs the built Basalt DXMT Windows and Unix
components into the bottle's private engine, copies the runtime DLL and JSON manifest to
`C:\basalt\runtime`, and writes the Khronos `ActiveRuntime` HKLM value. It then queries that value
and runs `loader_smoke.exe` through the bottle's Wine executable, requiring the managed DXMT
environment to advertise `XR_KHR_D3D11_enable`.

The individual `bottle install-dxmt` and `bottle install-runtime` commands are available for
diagnosis, but `prepare` is the normal idempotent path.

## Profiles

Profiles support `direct`, `steam`, `bsmanager`, and `itch` sources. The source records launcher
intent; the executable and arguments remain explicit so the CLI does not guess per-user install
locations.

```sh
swift run --package-path streamer basaltctl profile add beat-saber-steam \
  --bottle beat-saber --source steam \
  --exe 'C:\Program Files (x86)\Steam\steam.exe' \
  --arg -applaunch --arg 620980 \
  --env STEAM_COMPAT_CONFIG=basalt

swift run --package-path streamer basaltctl profile list
swift run --package-path streamer basaltctl profile show beat-saber-steam
```

Repeat `--arg VALUE` and `--env KEY=VALUE` as needed. `--cwd HOST_PATH` optionally selects the
Wine process's host working directory. `--game-root PATH` optionally names the game's install
folder (for a Steam game it defaults to the `steamapps/common/<Game>` folder of `--exe`).
`scripts/play.zsh` keeps the session open while any Windows program from that folder is running,
because some games start a second program and exit (The Lab starts Robot Repair).

## OpenComposite

OpenVR games (such as The Lab) need OpenComposite as their `openvr_api.dll`. Basalt does not
download, link, or redistribute OpenComposite (GPL-3.0); build it locally from pinned source with
`runtime/scripts/build-opencomposite.zsh`, or supply your own matching-bitness build. The build,
Basalt's patches, the OpenVR proxy, presets, and a per-game checklist are in
[the OpenComposite guide](OPENCOMPOSITE.md).

Install it into one game by naming the exact game DLL target inside the managed prefix:

```sh
swift run --package-path streamer basaltctl opencomposite install beat-saber-steam \
  --artifact runtime/build/opencomposite/out/openvr_api.dll \
  --target "$HOME/Library/Application Support/BasaltVR/Bottles/beat-saber/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/Beat Saber/Beat Saber_Data/Plugins/x86_64/openvr_api.dll"
```

The installer requires an `MZ` PE artifact and an `openvr_api.dll` destination below that
bottle's prefix. If the game DLL exists, its first version is retained as
`openvr_api.dll.basalt-original`. The generated `opencomposite.ini` uses the D3D11 path
(`initUsingVulkan=false`). `--preset alyx`, `--proxy`, and `--ini KEY=VALUE` are described in the
OpenComposite guide. A Steam update or "Verify integrity of game files" can restore Valve's DLL;
run the install command again if that happens.

## Launch

Start the native streamer first; it creates the authenticated loopback control file. Pass the
BlackHole input explicitly when game audio is wanted:

```sh
swift run -c release --package-path streamer basalt-streamer \
  --wired --runtime /tmp/basalt-control \
  --audio-device 'BlackHole 2ch' --route-audio
```

In another terminal:

```sh
swift run -c release --package-path streamer basaltctl run beat-saber-steam \
  --control-file /tmp/basalt-control -- --optional-game-argument
```

The run command refuses incomplete bottles or a missing control file. It maps that file into the
Wine `Z:` drive, enables the private DXMT IOSurface gate, applies the profile environment, and
starts the explicit executable. Extra arguments after `--` are appended for that invocation only.

OpenComposite's `openxr` branch has no `enableAudio` option and aborts on unknown options, so
Basalt no longer writes it. For game audio, set BlackHole to 48 kHz in Audio MIDI Setup and let
`--route-audio` temporarily direct application output into the loopback; the streamer restores
the prior Mac output on shutdown. The management
app adds this flag automatically. Direct CLI users with an existing Multi-Output route can omit
it. Validate the host side with `basalt-streamer --list-audio-devices` and
`basalt-streamer audio-loopback-selftest --device 'BlackHole 2ch'`.

macOS returns silence from BlackHole unless the app that runs `basalt-streamer` has Microphone
access. The streamer asks for access before it captures and, if access is denied, stops with the
System Settings action to take. A terminal that cannot ask (for example one embedded in an app
without the audio-input entitlement) gets no prompt; run the command from Terminal.app instead.

## Steam

Install Steam into the bottle by running Valve's `SteamSetup.exe /S` with the bottle's Wine and
`WINEPREFIX`. With the pinned engine the silent installer has been seen to crash after it copied
its files; the client still works because `steam.exe` updates itself on first start (stop the
crashed installer with the bottle's `wineserver -k`). Then create a Steam profile for the client.
The helper scripts below expect one named `steam` in a bottle named `pcvr`:

```sh
EXE='C:\Program Files (x86)\Steam\steam.exe'
CWD="$HOME/Library/Application Support/BasaltVR/Bottles/pcvr/prefix/drive_c/Program Files (x86)/Steam"
swift run --package-path streamer basaltctl profile add steam --bottle pcvr --source steam \
  --exe "$EXE" --cwd "$CWD"
```

`basaltctl steam start PROFILE [--log PATH]` takes the bottle from a Steam (or BSManager)
profile, installs Basalt's Steam web helper compatibility shim (it fixes a black Steam window),
and starts that bottle's `steam.exe` with `-inhibitbootstrap -noverifyfiles -no-cef-sandbox`. It
returns while Steam keeps running. The installer recognizes any Basalt shim build and never
preserves a shim as Steam's original helper, which would make the shim launch itself in a loop.

`scripts/steam.zsh` wraps this for signing in and downloading games without the streamer:
`scripts/steam.zsh` starts Steam, `scripts/steam.zsh stop` closes it cleanly (and stops the
bottle's Wine only if needed), and `scripts/steam.zsh status` reports it. It uses the `pcvr` bottle
and its `steam` profile unless `BASALT_BOTTLE` or `BASALT_STEAM_PROFILE` say otherwise.

`basaltctl profile` has `list`, `show`, and `add`; `add` with an existing name replaces that
profile. For Beat Saber (app 620980), `basaltctl run` turns `steam.exe -applaunch 620980` into a
direct launch of `Beat Saber.exe`, so Steam must already be running. A profile can also name a
game executable directly and pass `--env SteamAppId=<id> --env SteamGameId=<id>` so the game finds
the running Steam without a `steam_appid.txt`.

## One-command sessions

`scripts/play.zsh PROFILE` runs a whole session from the repository root: it checks the Quest
(USB if a Quest is on the cable, otherwise Wi-Fi), closes any Steam already running in the
profile's bottle (a game started from a running Steam inherits that Steam's old environment),
starts `basalt-streamer` with BlackHole audio when BlackHole is installed, starts Steam first for
Steam profiles that need it, then runs the profile. Ctrl-C or the end of the game stops the game,
Steam, and the streamer. Logs go to `~/Library/Logs/BasaltVR/`; logs there older than 7 days
(`BASALT_LOG_KEEP_DAYS`) are deleted when a session starts.

| Option | Effect |
|---|---|
| `--usb`, `--wifi` | Force the link (`BASALT_TRANSPORT=auto\|usb\|wifi`) |
| `--quality normal\|high\|max` | Picture size and bitrate; default `high` on USB, `normal` on Wi-Fi (`BASALT_QUALITY`) |
| `--codec h264\|hevc` | Default `hevc` on USB, `h264` on Wi-Fi (`BASALT_CODEC`) |
| `--log-quest` / `--no-log-quest` | Save the Quest's `adb logcat` for the session (default on, only lines from this session, no `VideoRenderQualityTracker`, capped at 200 MB, `BASALT_QUEST_LOG_MAX_MB`) |

Flags win over the environment variables. The quality levels map to these streamer settings
(USB adds `--profile m3pro`, so 72 fps and low latency):

| Level | USB | Wi-Fi |
|---|---|---|
| `normal` | 1152×1216 per eye, 30 Mbps | 1344×1408 per eye, 20 Mbps |
| `high` | 1344×1408 per eye, 60 Mbps | 1344×1408 per eye, 30 Mbps |
| `max` | 1680×1760 per eye, 80 Mbps | 1680×1760 per eye, 40 Mbps |

`BASALT_WIFI_MBPS` overrides the Wi-Fi bitrate of every level. `max` may not hold 72 fps with
H.264, and HEVC cannot hold 72 fps at `max`; the script warns in both cases. See
[performance](PERFORMANCE.md) for the measurements behind these defaults.

At the start, the script restarts the ALVR app (`alvr.client.stable` only, on the chosen Quest)
because a session that ended badly can leave it unable to complete the USB handshake. If the
handshake still fails, it restarts the app and the streamer once more.

Some games start a second program and exit; The Lab's hub starts Robot Repair. After the
launched executable exits, `play.zsh` waits up to 10 s for another program, then keeps the
session open while any Windows program from the game's install folder runs in the bottle. That
folder is `steamapps/common/<Game>` of the profile's executable, or the profile's `gameRoot`
(`basaltctl profile add --game-root PATH`).
