# BasaltVR

Runs windows vr programs on mac.

Basically a vibecoded clone of MoltenVR. Only tested on steam beatsaber + bsmanager. Hardware tested: M3 Max, Quest 3+ALVr. 

**A clean-room, open-source PCVR streaming stack for Apple Silicon Macs.**

*(Basalt is what molten rock becomes when it cools down and solidifies in the open.)*

> [!WARNING]
> BasaltVR is an experimental developer preview. Its OpenXR runtime is not conformant or
> game-ready in the general case. Beat Saber is the narrow compatibility target, and setup still
> requires developer tooling. Do not treat milestone passes as a broad compatibility guarantee.

## Download

Download the latest Apple Silicon developer preview from
[GitHub Releases](../../releases). Each release includes a SHA-256 checksum and exact
limitations. The app requires macOS 14 or newer and is currently ad-hoc signed rather than
notarized.

For a complete setup, read the [management app guide](docs/MANAGEMENT.md) and
[bottle guide](docs/BOTTLES.md). The preview archive deliberately does not redistribute Wine,
ALVR, OpenComposite, BlackHole, games, or store credentials.

Verify a downloaded archive before opening it:

```sh
shasum -a 256 -c BasaltVR-0.1.0-macos-arm64.zip.sha256
```

Extract the ZIP, move `BasaltVR.app` to Applications if desired, and use **Open** from Finder's
context menu on first launch. The app's **Setup** page reports missing runtime, Wine, ADB, and
optional audio prerequisites. This preview is intended for technical users; it is not yet a
turnkey installer.

## What this project is

BasaltVR reimplements a PCVR-on-Apple-Silicon pipeline around Wine/GPTK,
[DXMT](https://github.com/3Shain/dxmt),
[OpenComposite](https://gitlab.com/znixian/OpenOVR), and
[ALVR](https://github.com/alvr-org/ALVR). It adds a Wine-facing OpenXR runtime, native macOS
composition and encoding, the ALVR streamer bridge, isolated bottle tooling, and a SwiftUI manager.

The project was developed clean-room from public behavior and open-source interfaces; no MoltenVR
source code was used. BasaltVR is independent and is not affiliated with or endorsed by MoltenVR,
Meta, Valve, Beat Games, or the upstream projects it interoperates with.

## Product target

The first complete user experience is intentionally narrow: launch a modded Windows build
of **Beat Saber** on an Apple Silicon Mac and play it on an ALVR headset with only a few
button clicks. The management app will expose practical streaming controls such as bitrate,
refresh rate, resolution, and codec while keeping the Wine/OpenComposite/OpenXR setup hidden
behind a launch profile. General PCVR support comes after that vertical path works reliably.

## Status

| Milestone | Description | Status |
|-----------|-------------|--------|
| **M1** | Display capture → VideoToolbox H.264 (low-latency) → TCP stream | ✅ working |
| **M2** | ALVR transport bridge — stream to a real headset running the ALVR client | ✅ stable 72 fps over USB on Quest 3 |
| M3 | OpenXR runtime: Windows PE ABI + native Metal compositor | ✅ D3D11 projection frames cross DXMT/IOSurface into the Swift streamer and reach the headset at 72 fps |
| **M4** | Tracking, controllers & haptics (ALVR input ↔ OpenXR actions) | ✅ automated HMD/Touch actions, spaces, velocity, loss/recovery, profiles, priority, and haptics pass; pinned Khronos `hello_xr` completes the external-app session path, and the live Quest gate is physically verified at 72 fps |
| M5 | Wine bottle tooling: isolated DXMT engine, OpenXR registration, OpenComposite, launch profiles | ✅ CLI complete; disposable managed-bottle acceptance passes |
| M6 | Audio (BlackHole) + USB streaming (adb) | ✅ 48 kHz stereo PCM reaches Quest over wired ALVR; live gate holds 1.536 Mbps with zero audio drops and audible headset output |
| M7 | Management app: setup wizard, Steam/Whisky/CrossOver library, launcher | 🟨 preview packaging works; Developer ID/notarization and clean-user live acceptance remain |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design and what each
milestone involves.

## Management app (milestone 7, in progress)

The native SwiftUI management app wraps the existing bottle and streaming tools. It checks the Mac
and dependencies; discovers Basalt, Whisky, and CrossOver bottles; reads installed Steam libraries
and local artwork; creates and edits launch profiles; owns streamer, Steam, installer, and game
processes; and graphs live Quest FPS, wire bitrate, and input-to-display latency. External bottles
are read-only until the user explicitly makes an isolated APFS-cloned Basalt copy.

```sh
# Check the local toolchain and run the contributor quality gate.
make doctor
make check

# Build every executable and run the development app.
make app
```

The app intentionally writes only to Basalt's managed data root. It discovers but never edits
CrossOver or Whisky originals. See [docs/MANAGEMENT.md](docs/MANAGEMENT.md) for the current workflow and
remaining M7 gates.

## Quickstart (milestone 1)

Requires macOS 14+ on Apple Silicon and Xcode command-line tools.
An M3 Max is an excellent development target: capture and H.264 encoding use Apple's
hardware media engine rather than CPU software encoding.

```sh
cd streamer
swift run          # grant Screen Recording permission when prompted, then re-run
```

In a second terminal (needs ffmpeg: `brew install ffmpeg`):

```sh
ffplay -probesize 32 -analyzeduration 0 -fflags nocache -flags low_delay -framedrop -f h264 tcp://127.0.0.1:9999
```

You should see your desktop mirrored with sub-100 ms latency — hardware-encoded exactly the
way frames will be encoded for the headset. Flags: `--port`, `--fps`, `--mbps`, `--bind`,
`--wireless`, `--wired` (see `--help`; `--discover` remains as a legacy alias).

### Quest over USB (recommended while the transport is being developed)

Install ADB once, enable Developer Mode and USB debugging on the Quest, and install the ALVR
v20 client on it:

```sh
brew install android-platform-tools
cd streamer
swift run -c release basalt-streamer --wired --mbps 12
```

Use a data-capable USB cable and accept the debugging prompt inside the headset. `--wired`
finds the authorized physical Quest, brings ALVR to the foreground, creates ADB forwards for
control port 9943 and stream port 9944, negotiates ALVR's wired mode, and carries the video and
headset uplink over TCP. Ctrl-C removes the port forwards. It does not need `--discover`, Wi-Fi,
or `--bind`; `--wired` and `--discover` are intentionally mutually exclusive.

For Wi-Fi instead, open ALVR on the headset and run:

```sh
swift run -c release basalt-streamer --wireless --mbps 20
```

The release build is recommended for headset use so Swift's desktop composition and packet
path are optimized. The first run takes longer while it compiles; later launches reuse the build.

### Game audio over BlackHole (milestone 6)

Basalt can capture a named CoreAudio loopback input and send ALVR v20's raw 48 kHz stereo PCM
stream over the same UDP or wired TCP connection as video. BlackHole remains explicit so Basalt
never captures a physical microphone by accident:

```sh
# Confirm the exact device name and run a two-second, device-local 440 Hz gate.
swift run --package-path streamer basalt-streamer --list-audio-devices
swift run --package-path streamer basalt-streamer audio-loopback-selftest \
  --device 'BlackHole 2ch'

# Normal wired headset run with game audio enabled.
swift run -c release --package-path streamer basalt-streamer \
  --wired --audio-device 'BlackHole 2ch' --route-audio --mbps 12
```

Set BlackHole 2ch to 48 kHz in Audio MIDI Setup. `--route-audio` temporarily makes BlackHole the
default application output and restores the prior output when Basalt stops; the management app
adds this flag automatically whenever audio is enabled. Direct CLI users who already route through
a macOS Multi-Output Device can omit the flag to retain local monitoring. The capture backend
requests interleaved little-endian PCM16 and rejects incomplete stereo frames. Each ALVR audio
packet is self-contained; the sender holds at most one pending block, dropping instead of
accumulating audio latency if transport stalls.

The M6 live M3 Max → Quest 3 USB gate sustained about 93.8 audio blocks/s, 1.536 Mbps PCM
(1.563 Mbps including ALVR sharding), no audio drops, and at most 3.3 ms observed audio write time
while video and Quest statistics continued. The separate local loopback gate captured 98,304
stereo frames from a generated 440 Hz BlackHole signal. The same tone was then captured and sent
through the live wired session and confirmed audible through the Quest 3 speakers. Microphone
backhaul is intentionally out of scope.

Streaming controls already available to the future launcher/profile UI are also exposed by the CLI:

```sh
# Default quality-focused headset profile
swift run -c release basalt-streamer --wired

# Smoother fallback for a thermally constrained headset
swift run -c release basalt-streamer --wired --mbps 20 --resolution balanced

# Custom per-eye dimensions; they must be even and within headset capabilities
swift run -c release basalt-streamer --wired --resolution 1680x1760
```

Resolution presets are `performance` (896×944), `balanced` (1152×1216), and
`quality` (1344×1408, default). The quality-focused headset baseline is wired USB, 72 fps,
30 Mbps, and low latency. `--fps`, `--mbps`, `--resolution`, and `--latency` form a reusable
stream-settings model rather than hard-coded demo constants. Select balanced latency if low
introduces head-motion unevenness.

In one wired M3 Max → Quest 3 validation, `--latency low` held approximately 72 fps while
reducing the Quest-reported decoder queue from roughly 10–12 ms with balanced latency to
roughly 3–4 ms. Quest-reported input-to-display latency fell from roughly 55–58 ms to
47–51 ms in the same sample. A separate `--resolution quality --mbps 20` run also held
approximately 72 fps at 1344×1408 per eye (2688×1408 encoded), with Quest decode near 21 ms
and steady local capture-to-encode latency near 12 ms. These are encouraging transport-pipeline
measurements. Low latency is now the user-selected default alongside the quality preset and a
30 Mbps target; subjective quality during head motion and sustained thermal behavior still need
monitoring. Compare one setting at a time from a cool headset so resolution, bitrate, latency
preset, and thermal state are not confounded.

With either headset mode, the desktop is drawn as a smaller virtual monitor in both halves of a
side-by-side stereo frame. Its placement is calibrated from the Quest's reported IPD and
asymmetric eye fields of view. The default quality preview is 1344×1408 per eye and uses H.264
High Profile. Capture defaults to 72 Hz, and the streamer negotiates the supported headset rate
closest to `--fps`.

The USB quickstart starts at 30 Mbps. The temporary desktop path does not yet implement ALVR's
foveated encoder transform. `--mbps` is the fixed VideoToolbox target selected for the run;
Basalt does not silently lower it.

The demo keeps at most two frames in the encoder. Balanced latency asks the Quest decoder for a
bounded 1.5-frame smoothing target; `--latency low` conservatively reduces that to 1.3 while
keeping the same smoothing history. ScreenCaptureKit only creates new surfaces when desktop pixels change,
so Basalt retains the latest valid surface and submits it at the requested video cadence with fresh
timestamps; missed slots are skipped rather than queued. Unchanged stereo composition is cached.
The desktop preview is a static, head-centered transport test: it is
not a 3D world-anchored monitor and cannot respond correctly to head rotation. Correct motion
requires M3's pose-aware, per-eye OpenXR/Metal renderer; applying a 2D transform to captured pixels
only produces tilt and distortion, so Basalt deliberately does not do that.

Its Wi-Fi UDP socket is nonblocking with a bounded kernel buffer. USB uses separate 1 MiB TCP
send/receive buffers and one 50 ms deadline for an entire encoded access unit; a partial timeout
closes the stream rather than corrupting its framing. If encoding or transport falls behind,
Basalt bounds stale work instead of building an unbounded latency-inducing queue. The periodic
transport line reports actual sent FPS, wire bitrate, maximum write time, largest frame, IDRs, and
reused tracking timestamps so stalls can be localized instead of inferred from decoder latency.
It also prints local capture-to-encode latency every five seconds.
Once headset tracking timestamps are available, video uses the Quest's OpenXR clock domain;
Quest statistics then report display FPS, input-to-display, decode, decoder-queue, and vsync
latency. These are useful client-pipeline diagnostics, but the temporary desktop capture is not
rendered from the matching head pose, so the number is not yet a trustworthy motion-to-photon
measurement. Recovery IDRs are rate-limited so decoder saturation cannot create a keyframe storm.

Run the tests with `swift test` (they cover option parsing, AVCC→Annex-B conversion, ALVR
discovery/control/session packets, USB-device selection, UDP video, TCP video/uplink framing,
and a live loopback round-trip through the local preview server).

### OpenXR runtime checkpoint (milestone 3)

The runtime is a real x86-64 Windows DLL, not a host-native mock. It passes strict negotiation,
instance-lifecycle, HMD-system, and stereo-view tests through the official Khronos Windows loader
under WhiskyWine. On a development Mac with Whisky installed:

```sh
brew install cmake mingw-w64
runtime/scripts/test-wine.zsh
```

The separate DXMT acceptance command provisions only an ignored, disposable Wine tree and prefix:

```sh
runtime/scripts/test-dxmt.zsh
```

That test now passes `XR_KHR_D3D11_enable` requirements, device/session validation, `VIEW` and
`LOCAL` space lifecycle, session-state events, CTS-shaped frame call ordering, and two independent
three-image NT-handle-shareable swapchains through the official loader. With the Basalt DXMT fork,
projection frames also cross the IOSurface control boundary and encode through the Swift streamer.
The extension is capability-gated: Whisky/D3DMetal still sees it as unavailable. This does not
prove a real game install yet—per-game compatibility remains. The external application visual
gate is complete, and the live HMD/Touch action and haptic path is covered by the deterministic
control-daemon test. See [runtime/README.md](runtime/README.md) for the exact boundary.

### Visible OpenXR → headset integration test

Connect the authorized Quest over USB, open the ALVR client, stop any existing streamer, and run:

```sh
runtime/scripts/test-headset.zsh 60
```

The command safely stages the pinned Basalt DXMT fork only in the disposable test Wine tree,
starts the streamer in `--runtime --wired` mode, and renders a green controller marker plus a
world-fixed depth constellation over a blue stereo frame for 60 seconds. Fused stereo and a stable
world grid prove the calibrated view/head path; seeing both eyes proves the M3 graphics path:
D3D11 → DXMT → IOSurface → `RuntimeLink` → VideoToolbox → ALVR USB → Quest. It restores stock
DXMT and removes ADB forwards on exit. The console additionally requires fresh ALVR HMD and left
Touch-controller poses, validates OpenXR action/profile/binding state, and emits one short left-hand
haptic pulse. Move your head to test world locking; move the left controller toward/away to change
the marker's position and apparent size; squeeze the grip to enlarge it and shift it yellow. This
is an input-responsive diagnostic, not a game scene; audio and
game compatibility are not covered. Wired setup sends a normal
wake event before foregrounding ALVR; keep the headset awake if its proximity sensor puts it back
to sleep. The test refuses to start its producer until the Quest sends a fresh tracking timestamp,
preventing a false pass at “stream will begin soon.”

The stricter external-application gate builds Khronos' real `hello_xr` D3D11 sample from pinned
official 1.1.61 source rather than using Basalt's shaped producer:

```sh
runtime/scripts/test-khr-hello-xr-headset.zsh
```

That target now passes a live Quest run against Basalt: `hello_xr` reached `FOCUSED`, created two
D3D11 eye swapchains, localized Touch actions, rendered for roughly 14 seconds, and traversed
`STOPPING→IDLE→EXITING` cleanly. This proves the external application's runtime, transport, and
session path. The companion live Quest scene is physically verified with fused, level/world-fixed
stereo, tracked controller response, analog squeeze, and haptics at 72 fps. When `hello_xr` runs
interactively, expect world-fixed cubes and tracked hands; use the left menu button for a clean
exit. Basalt intentionally rejects `arraySize=2` D3D11 swapchains because the native
handoff consumes one IOSurface per eye, causing Unity-style engines to select their multipass
`arraySize=1` fallback instead of accepting a broken texture-array path.

### Managed Wine bottles and launch profiles (milestone 5)

`basaltctl` owns only `~/Library/Application Support/BasaltVR` by default. It discovers the
pinned Wine 11.10/DXMT toolchain plus installed WhiskyWine or GPTK engines, but it patches DXMT
only into an APFS-cloned private engine in a Basalt-managed bottle. Shared Whisky, GPTK, and
CrossOver installations are never modified.

```sh
# Inspect prerequisites and create the supported VR bottle.
swift run --package-path streamer basaltctl doctor
swift run --package-path streamer basaltctl bottle create beat-saber \
  --engine pinned-wine-11.10-dxmt-0.80
swift run --package-path streamer basaltctl bottle prepare beat-saber

# Persist a Steam launch profile (direct, bsmanager, and itch are also supported).
swift run --package-path streamer basaltctl profile add beat-saber-steam \
  --bottle beat-saber --source steam \
  --exe 'C:\Program Files (x86)\Steam\steam.exe' \
  --arg -applaunch --arg 620980
```

`bottle prepare` installs the Basalt DXMT fork, stages and registers the OpenXR runtime at the
Khronos HKLM key, and runs an official-loader smoke inside that exact bottle. OpenComposite stays
a separately supplied GPLv3 DLL: `opencomposite install` validates a PE artifact, accepts only an
`openvr_api.dll` target inside the managed prefix, preserves the first original as
`openvr_api.dll.basalt-original`, and writes the D3D11 configuration beside it.

Start `basalt-streamer --wired --runtime /tmp/basalt-control`, then launch the saved profile with
`basaltctl run beat-saber-steam --control-file /tmp/basalt-control`. The launcher injects only the
runtime control path and the gated DXMT setting, plus environment values explicitly stored in the
profile. See [docs/BOTTLES.md](docs/BOTTLES.md) for the complete command reference and safety
boundary.

## Security

The stream is your screen, so the streamer is conservative by default:

- **Local-only by default.** It binds `127.0.0.1`; nothing on the network can connect.
  Pass `--bind <ip>` (e.g. `--bind 0.0.0.0`) to accept LAN clients — it will warn you,
  since anyone on the network can then watch the stream.
- **Slow clients get dropped, not buffered.** A client more than ~8 MB behind is
  disconnected instead of queueing your screen contents in memory indefinitely.
- **At most 8 concurrent clients**, and Ctrl-C tears down capture and sockets cleanly.
- `--wireless` (off by default; legacy alias `--discover`) listens on UDP 9943 for ALVR headsets, connects back to
  the announcing IP on TCP 9943, negotiates the supported refresh rate closest to `--fps`, sends
  `StartStream`, validates `StreamReady`, and connects UDP port 9944 to send ALVR-sharded
  VideoToolbox H.264 desktop frames. The live control loop handles headset view calibration,
  keepalives, and IDR recovery requests. The UDP uplink reads tracking timestamps for frame
  pacing and Quest statistics for end-to-end latency. HMD and corrected Touch grip poses,
  controller velocity, authoritative per-frame controller-presence masks, button deltas, active
  interaction profiles, calibrated views, and reverse haptics are bridged into the OpenXR runtime.
  A missing-hand mask clears pose and velocity immediately; a newer motion sample recovers them.
- `--wired` talks only to localhost ports forwarded to one authorized physical USB device by
  ADB. It does not expose the screen on the LAN and removes those forwards during clean shutdown.
- Game audio is off unless `--audio-device` is passed. The name must resolve to one explicit
  CoreAudio input, and only that loopback device is captured; use `--route-audio` to temporarily
  direct application output to it and `--list-audio-devices` to audit the selection before
  streaming. Manager-launched sessions add the routing flag automatically.

## Why this exists

MoltenVR is closed-source (binaries only, 7-day trial, license key via Patreon), yet most of
its stack is open source. The genuinely novel work — the OpenXR runtime and the glue — is
worth having in the open. That's this project.

## Contributing and releases

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and pull-request expectations,
[SUPPORT.md](SUPPORT.md) for setup and compatibility-reporting help,
[SECURITY.md](SECURITY.md) for private vulnerability reporting, and
[docs/MAINTAINING.md](docs/MAINTAINING.md) for triage and repository operations.
[docs/RELEASING.md](docs/RELEASING.md) defines the reproducible preview-release process, and
product and consumer-release work is tracked in [ROADMAP.md](ROADMAP.md).

## License

BasaltVR code is available under the [MIT License](LICENSE). Components it orchestrates keep their own licenses
(ALVR: MIT; pinned DXMT v0.80: MIT; OpenComposite: GPLv3 — shipped as a separate artifact,
never linked in). See [third-party notices](THIRD_PARTY_NOTICES.md) for the distribution boundary.
