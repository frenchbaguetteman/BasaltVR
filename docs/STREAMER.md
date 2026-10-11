# Streamer command line

`basalt-streamer` is the native macOS half of BasaltVR: it encodes frames with VideoToolbox and
carries them to an ALVR headset client. The management app drives it for you; this guide covers
running it directly, which is useful for development, transport debugging, and headset tests.

Requires macOS 14+ on Apple Silicon and Xcode command-line tools. Capture and H.264 encoding use
Apple's hardware media engine rather than CPU software encoding.

## Local desktop preview

The simplest pipeline check mirrors your desktop over a local TCP H.264 stream:

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

## Quest over USB (recommended)

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

## Quest over Wi-Fi

Open ALVR on the headset and run:

```sh
swift run -c release basalt-streamer --wireless --mbps 20
```

The release build is recommended for headset use so Swift's desktop composition and packet
path are optimized. The first run takes longer while it compiles; later launches reuse the build.

## Game audio over BlackHole

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

## Stream settings

The streaming controls the management app exposes are also available on the command line:

```sh
# Default quality-focused headset profile
swift run -c release basalt-streamer --wired

# Smoother fallback for a thermally constrained headset
swift run -c release basalt-streamer --wired --mbps 20 --resolution balanced

# Custom per-eye dimensions: even, and at most 1680x1760 with --runtime
swift run -c release basalt-streamer --wired --resolution 1680x1760
```

Resolution presets are `performance` (896×944), `balanced` (1152×1216), and
`quality` (1344×1408, default). The quality-focused headset baseline is wired USB, 72 fps,
30 Mbps, and low latency. `--fps`, `--mbps`, `--resolution`, and `--latency` form a reusable
stream-settings model rather than hard-coded demo constants. Ultra latency requests a one-frame
decoder target with less history; select low or balanced if it introduces head-motion unevenness.

`--mbps` is the fixed VideoToolbox target selected for the run; Basalt does not silently lower it.
Capture defaults to 72 Hz, and the streamer negotiates the supported headset rate closest to
`--fps`. Video uses H.264 High Profile. ALVR's foveated encoder transform is not implemented yet.

### Latency presets

The encoder keeps at most two frames in flight. Balanced latency asks the Quest decoder for a
bounded 1.5-frame smoothing target; `--latency low` conservatively reduces that to 1.3 while
keeping the same smoothing history. `--latency ultra` targets one frame and reduces the history
weight from 0.8 to 0.5, trading jitter tolerance for lower latency.

### Measurements

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

## Desktop preview mode

Without `--runtime`, the headset modes draw the desktop as a smaller virtual monitor in both
halves of a side-by-side stereo frame. Its placement is calibrated from the Quest's reported IPD
and asymmetric eye fields of view.

ScreenCaptureKit only creates new surfaces when desktop pixels change, so Basalt retains the
latest valid surface and submits it at the requested video cadence with fresh timestamps; missed
slots are skipped rather than queued. Unchanged stereo composition is cached.

The desktop preview is a static, head-centered transport test: it is not a 3D world-anchored
monitor and cannot respond correctly to head rotation. Correct motion comes from the pose-aware,
per-eye OpenXR runtime path (`--runtime`); applying a 2D transform to captured pixels only
produces tilt and distortion, so Basalt deliberately does not do that.

## Transport behavior and diagnostics

The Wi-Fi UDP socket is nonblocking with a bounded kernel buffer. USB uses separate 1 MiB TCP
send/receive buffers and one 50 ms deadline for an entire encoded access unit; a partial timeout
closes the stream rather than corrupting its framing. If encoding or transport falls behind,
Basalt bounds stale work instead of building an unbounded latency-inducing queue.

The periodic transport line reports actual sent FPS, wire bitrate, maximum write time, largest
frame, IDRs, and reused tracking timestamps so stalls can be localized instead of inferred from
decoder latency. It also prints local capture-to-encode latency every five seconds.

Once headset tracking timestamps are available, video uses the Quest's OpenXR clock domain;
Quest statistics then report display FPS, input-to-display, decode, decoder-queue, and vsync
latency. In desktop preview mode these are useful client-pipeline diagnostics, but the captured
desktop is not rendered from the matching head pose, so the number is not a trustworthy
motion-to-photon measurement. Recovery IDRs are rate-limited so decoder saturation cannot create
a keyframe storm.

## Security model

The stream is your screen, so the streamer is conservative by default:

- **Local-only by default.** It binds `127.0.0.1`; nothing on the network can connect.
  Pass `--bind <ip>` (e.g. `--bind 0.0.0.0`) to accept LAN clients — it will warn you,
  since anyone on the network can then watch the stream.
- **Slow clients get dropped, not buffered.** A client more than ~8 MB behind is
  disconnected instead of queueing your screen contents in memory indefinitely.
- **At most 8 concurrent clients**, and Ctrl-C tears down capture and sockets cleanly.
- `--wireless` (off by default; legacy alias `--discover`) listens on UDP 9943 for ALVR headsets,
  connects back to the announcing IP on TCP 9943, negotiates the supported refresh rate closest to
  `--fps`, sends `StartStream`, validates `StreamReady`, and connects UDP port 9944 to send
  ALVR-sharded VideoToolbox H.264 frames. The live control loop handles headset view calibration,
  keepalives, and IDR recovery requests. The UDP uplink reads tracking timestamps for frame
  pacing and Quest statistics for end-to-end latency. HMD and corrected Touch grip poses,
  controller velocity, authoritative per-frame controller-presence masks, button deltas, active
  interaction profiles, calibrated views, and reverse haptics are bridged into the OpenXR runtime.
  A missing-hand mask clears pose and velocity immediately; a newer motion sample recovers them.
- `--wired` talks only to localhost ports forwarded to one authorized physical USB device by
  ADB. It does not expose the screen on the LAN and removes those forwards during clean shutdown.
- The runtime control socket is loopback-only and authenticated by a per-session token written to
  a `0600` control file.
- Game audio is off unless `--audio-device` is passed. The name must resolve to one explicit
  CoreAudio input, and only that loopback device is captured; use `--route-audio` to temporarily
  direct application output to it and `--list-audio-devices` to audit the selection before
  streaming. Manager-launched sessions add the routing flag automatically.

## Tests

`swift test --package-path streamer` covers option parsing, AVCC→Annex-B conversion, ALVR
discovery/control/session packets, USB-device selection, UDP video, TCP video/uplink framing,
the runtime control protocol, and a live loopback round-trip through the local preview server.
