# Streamer command line

`basalt-streamer` is the native macOS half of BasaltVR: it encodes frames with VideoToolbox and
carries them to an ALVR headset client. The management app drives it for you; this guide covers
running it directly, which is useful for development, transport debugging, and headset tests.

Requires macOS 14+ on Apple Silicon and Xcode command-line tools. Capture and H.264/HEVC encoding
use Apple's hardware media engine rather than CPU software encoding.

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
way frames will be encoded for the headset. Flags: `--port`, `--fps`, `--mbps`, `--codec`,
`--bind`, `--wireless`, `--wired` (see `--help`; `--discover` remains as a legacy alias). With
`--codec hevc`, use `-f hevc` instead of `-f h264` (the streamer prints the exact command).

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

`scripts/install-quest-client.zsh` installs the official ALVR v20.14.1 Android client
(`alvr_client_android.apk` from the ALVR GitHub release; set `ALVR_APK` to its path). It checks the
APK's pinned SHA-256 on a private copy, installs that copy, and asks before it removes a different
ALVR version from the Quest.

## Quest over Wi-Fi

Open ALVR on the headset and run:

```sh
swift run -c release basalt-streamer --wireless --mbps 20
```

The release build is recommended for headset use so Swift's desktop composition and packet
path are optimized. The first run takes longer while it compiles; later launches reuse the build.

There is no pairing or Trust step. The ALVR client broadcasts a beacon on UDP 9943; Basalt is the
server, so it connects back to the announcing IP without a client allow-list (stock ALVR's
"Trust" button belongs to its own dashboard, which Basalt replaces). On the first run macOS may
ask to allow incoming connections for `basalt-streamer`, or Local Network access for your
terminal app: click Allow. The Mac and the Quest must be on the same subnet; guest or
client-isolated Wi-Fi blocks the broadcast.

`scripts/play.zsh` picks the link for you: USB when a USB Quest is attached, otherwise Wi-Fi.
Force one with `--usb` or `--wifi`; its quality levels and codec defaults are listed in
[the bottle guide](BOTTLES.md#one-command-sessions). Wi-Fi streaming itself does not need adb.
To let the scripts check and open ALVR without a cable, run `scripts/quest-wireless.zsh` once
with the Quest plugged in: it runs `adb tcpip 5555`, connects to the Quest's Wi-Fi address, and
saves that address in `~/Library/Application Support/BasaltVR/quest-ip`. Later, without the
cable, the same command reconnects (`--ip <quest-ip>` sets a new address; `status` shows what adb
sees). The Quest forgets adb over Wi-Fi when it restarts; plug it in and run the script again.

If the same Quest is listed twice by `adb devices` (USB serial and `<quest-ip>:5555`), the scripts
pick one serial and pass `-s` on every adb command: a USB device wins, then the saved Quest IP,
then the lowest serial. Only Quest models are chosen; emulators and other Android devices are
ignored and never get a command. `--wired` only ever uses a USB serial and says so if adb only
sees the Quest over Wi-Fi.

Wi-Fi uses UDP video with a bounded send queue. Congestion drops stale frames, recovers with an IDR
(see "Loss recovery" below), and an adaptive controller lowers the encoder bitrate (by 20% steps,
down to a third of `--mbps`, never below 8 Mbps) and restores it slowly when the stream is healthy.
USB has no such adaptation and keeps the fixed bitrate. Expect more latency and jitter than USB and
a lower practical bitrate (20 Mbps here versus the 30 Mbps USB default); a 5 or 6 GHz network with
the Mac on Ethernet or 5 GHz helps most.

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

macOS delivers silence from any input, BlackHole included, when the app that runs
`basalt-streamer` has no Microphone permission. The streamer therefore asks for Microphone access
before it captures, and if access is denied it stops with the exact System Settings action instead
of streaming silence. Terminals embedded in apps without the audio-input entitlement cannot ask;
run the streamer from Terminal.app in that case.

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
`--fps` (the Quest 3 reports 72, 80, 90, and 120 Hz). With `--runtime`, the OpenXR runtime's
`xrWaitFrame` paces to that negotiated rate. Video uses H.264 High Profile by default. ALVR's
foveated encoder transform is not implemented yet.

`--codec hevc` encodes HEVC Main (8-bit 4:2:0) on the hardware encoder instead (`h265` is
accepted as an alias). It is sent exactly as ALVR's own servers send it: an Annex-B stream whose
IDR access units start with VPS, SPS, and PPS, and a `DecoderConfig` control packet with
`CodecType::Hevc` (1) and the VPS+SPS+PPS buffer, which the Quest passes to MediaCodec
(`video/hevc`) as `csd-0`. The stream configuration also names the codec
(`video.preferred_codec`). Keyframes are IDR pictures (NAL type 20), so the loss-recovery gate
below works unchanged. The streamer's default stays H.264 and `--profile m3pro` does not select
a codec. `scripts/play.zsh` uses HEVC by default over USB, where a headset A/B in The Lab measured
lower latency and Quest decode time than H.264 at the same settings, and H.264 over Wi-Fi; see
[performance](PERFORMANCE.md#hevc). Do not use HEVC at 1680×1760 per eye: on an M3 Pro it takes
about 23 ms per frame, more than a 72 Hz frame.

`--profile m3pro` selects balanced resolution, 72 fps, 30 Mbps, and low latency for an M3 Pro
over USB; explicit flags still win. `--idr-interval <seconds>` (default 2) sets the longest gap
between periodic IDR frames, and `--entropy cabac|cavlc` (default CABAC) the H.264 entropy
coding (an error with `--codec hevc`, which always uses CABAC). Both exist for headset A/B
measurements; see [performance](PERFORMANCE.md). At startup the streamer lists any
VideoToolbox property that the low-latency encoder refused (on macOS 26:
`MaxFrameDelayCount` and `PrioritizeEncodingSpeedOverQuality`).

By default the stream configuration asks the Quest to predict controller poses as far ahead as
the head (`--controller-prediction full`). ALVR's own default predicts controllers 2–3 frames
less and relies on SteamVR to extrapolate the rest; Basalt has no such step, so
`--controller-prediction alvr` exists only for comparison.

Touch poses: the ALVR client adds its own SteamVR-oriented grip offset (5 mm, -15° pitch); the
streamer removes it, so the runtime exposes Meta's grip pose. `--hand-tracking on` (default)
uses Quest optical hand tracking for a hand without a controller: the game gets an emulated
Touch controller (pinch = trigger, fist = grip, ALVR's gesture set) and the hand skeleton through
`XR_EXT_hand_tracking`. Switching between hands and controllers works mid-session.
`--hand-tracking off` ignores tracked hands. Details: [hand tracking](HAND-TRACKING.md).

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
send/receive buffers and keeps one encoded access unit in flight; while it waits, newer frames are
not encoded at all (see "Loss recovery"). The adb USB link can pause for over a second; a pause
only delays that frame, and tracking keeps being read during the wait. Only 5 s without any write
progress (the control connection's silence limit) closes the stream, because a partial write
cannot be abandoned without corrupting its framing. If encoding or transport falls behind,
Basalt bounds stale work instead of building an unbounded latency-inducing queue.

### Loss recovery

Basalt's H.264 SPS forbids `frame_num` gaps. If an encoded reference frame never reaches the
Quest, every later P-frame references a picture the decoder does not have: the Quest logs
`h264DpbFillFrameNumGap: Frame num gap is not allowed` and shows corrupt, flickering pictures until
the next IDR. `VideoLossRecoveryGate` (`streamer/Sources/BasaltCore/VideoLossRecovery.swift`)
prevents this in two ways:

- **Drop before encoding.** When the video transport would drop a frame (a USB write still in
  flight, a failed transport, or, for desktop frames, no fresh tracking timestamp), the frame is
  not encoded. A frame that is never encoded leaves no `frame_num` gap, so the chain stays intact
  and no IDR is needed. VideoToolbox's own rate-control drops are also gap-free (measured: 111 of
  120 frames dropped, `frame_num` still continuous).
- **IDR gate after a loss.** When an encoded access unit is lost anyway (the transport became busy
  while it was encoding, a Wi-Fi shard did not fit the socket, its tracking timestamp was missing,
  the Quest asked for an IDR, or a new session started), every following P-frame is discarded and
  the next encode is forced to be an IDR (`kVTEncodeFrameOptionKey_ForceKeyFrame`). P-frames flow
  again only after an IDR; if that IDR is lost too, another one is forced. There is no time
  throttle on this path over USB. Over Wi-Fi, a second recovery IDR within 250 ms waits (frames
  are not encoded meanwhile) so a saturated link does not get a keyframe storm. Repeated Quest
  IDR requests are ignored only while a recovery IDR is in flight or was just delivered (100 ms
  over USB, 250 ms over Wi-Fi).

HEVC has no `frame_num`; its equivalent fault is a P-frame whose reference picture set names a
picture the Quest never received ("could not find ref with POC"), decoded against a missing
reference until the next IDR. The same gate prevents it: a frame that is not encoded is never in
any reference picture set, and VideoToolbox's HEVC keyframes are IDR pictures (NAL type 20,
POC reset, empty reference set), so any IDR starts a clean chain.
`VideoLossRecoveryEncoderTests` checks both codecs on real VideoToolbox output.

Periodic IDRs (`--idr-interval`, default 2 s) also end a recovery, but they are no longer needed for
it: a loss now costs one IDR on the next frame instead of corruption until the next periodic IDR.
Over USB, a longer `--idr-interval` only removes the periodic bitrate pulse.

### Headset disconnects and reconnects

The streamer outlives the ALVR client session. When the Quest sleeps (headset taken off), ALVR is
closed, or the link drops, the session ends and the streamer logs
`ALVR headset disconnected (<reason>)`. The OpenXR runtime and the game keep running. The session
ends on any of these signals:

- the control connection closes or fails;
- the USB stream closes or a video write fails (for example `Broken pipe`);
- no control packet arrives for 5 s. ALVR v20 clients send `KeepAlive` every 500 ms, so this
  catches a Wi-Fi headset that went out of range without a TCP reset.

On disconnect, Basalt detaches the stream, sends `INPUT_RESET` to the runtime (controllers go
inactive and head tracking goes stale), and resets the Wi-Fi encoder bitrate to `--mbps`. Then it
waits for the client. Runtime frames are skipped before composition and encoding until the client
is back, unless a local preview client is connected. Over USB, the streamer retries the handshake
on the adb-forwarded ports every 0.5 s. It also re-creates the adb forwards if adb dropped them, but
it does not wake the Quest or relaunch ALVR. Over Wi-Fi, the next ALVR beacon starts the next
handshake. A reconnect repeats the full handshake (StreamConfig, StartStream, StreamReady) and sends
an IDR with fresh decoder parameters. The Quest then sends its IPD/FOV again, and the runtime gets
the new view configuration. Reconnect failures are logged for the first attempt and then every
60th attempt. Only the first connection of a `--wired` run has the 10-attempt startup limit.

ALVR does not need continuous video. In the v20.14.1 client source, the video receive loop only
retries when no packet arrives (`client_core/src/connection.rs`), and the session times out only on
the control channel (`KEEPALIVE_TIMEOUT`). When no new frame is decoded, the renderer draws the last
decoded picture again with that picture's own pose (`client_openxr/src/stream.rs`,
`last_good_view_params`), so the last game image stays world-locked. Basalt's idle filler
(`RuntimeIdleVideoFiller`) therefore sends video only when the headset's picture must change. It
acts only after the game has submitted nothing for 0.5 s, and it retries at most every 100 ms. A
game at 30-60 fps submits a frame every 17-33 ms, so it never gets a filler frame.

- **After a game frame** (a slow game such as The Lab's Secret Shop at about 0.5 frames/s, or a
  hitch), Basalt sends nothing while the headset has the last frame. It re-encodes the last
  composed game image only if that image was never delivered (transport or encoder busy,
  VideoToolbox rate-control drop) or if the reference chain broke (a lost access unit, a Quest IDR
  request): a P-frame, or a forced IDR when the loss-recovery gate waits for one. The repeat keeps
  the game frame's Quest tracking timestamp, so the client reprojects it with the pose that it was
  rendered for. Its encoder presentation time is a few nanoseconds later, so VideoToolbox time
  still moves forward. The client keeps only the newest 1024 head poses, polled at 3x the display
  rate (2.8 s at 120 Hz), so Basalt does not repeat an image older than 2 s. The client's own copy
  of that image is then better than a re-send that the client would draw at a default pose. The
  composer keeps one extra output surface for the held image, so holding it does not reduce the
  frames in flight.
- **Before the first game frame** (loading, OpenComposite's probe session, the game not started
  yet), **after the runtime disconnects or a new game session replaces the old one**, and **at the
  start of each headset session**, Basalt sends a black frame with the newest tracking timestamp.
  It sends black until one black IDR is delivered on an intact chain. Thus the client has a decoder
  configuration and a defined picture.

The throttled log lines `OpenXR runtime idle with no game frame yet: sent N black filler
frame(s)` and `OpenXR runtime idle: re-sent the last game image N time(s)` report filler frames.
They also count in the pipeline line's `encoded` rate.

The periodic transport line reports actual sent FPS, wire bitrate, maximum write time, largest
frame, IDRs, and reused tracking timestamps so stalls can be localized instead of inferred from
decoder latency. It also prints local capture-to-encode latency every five seconds.

In headset mode a `pipeline t=…` line follows every 2 s from a timer, so it appears even when no
frame flows. It shows where frames were lost between tracking and the socket:

```
  pipeline t=123.5s: tracking 72.0/s (max gap 31.2 ms, 0 backward); runtime 70.0/s (0 untracked, 2 repeated pose); encoded 70.0/s (8.1 ms avg, 12.5 ms max); drops encoder-busy 0, compositor-busy 0, rate-control 0, network-busy 0, network 0, awaiting-IDR 0; pose age at send 24.0 ms avg, 40.0 ms max
```

`t` is seconds since the streamer started. `max gap` is the longest Mac-side gap between Quest
tracking packets, including a gap that is still open. `untracked` counts runtime frames located
without a fresh head pose (Quest timestamp 0), and `repeated pose` counts frames that reused the
previous frame's tracking timestamp. `rate-control` counts frames that VideoToolbox's low-latency
rate control dropped because they did not fit the bitrate. `network-busy` counts frames not
encoded because the transport was busy (harmless to the picture chain), `network` counts encoded
frames that were lost (each one starts an IDR recovery), and `awaiting-IDR` counts frames
discarded or not encoded while waiting for that IDR. `pose age at send` is the Mac-side time from
the tracking packet's arrival to the end of the video write for the frame rendered with it.

Once headset tracking timestamps are available, video uses the Quest's OpenXR clock domain;
Quest statistics then report display FPS, input-to-display, decode, decoder-queue, and vsync
latency. In desktop preview mode these are useful client-pipeline diagnostics, but the captured
desktop is not rendered from the matching head pose, so the number is not a trustworthy
motion-to-photon measurement.

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
  interaction profiles, hand skeletons (with gesture-emulated Touch input), calibrated views, and
  reverse haptics are bridged into the OpenXR runtime.
  A missing-hand mask clears pose and velocity immediately; a newer motion sample recovers them.
- `--wired` talks only to localhost ports forwarded to one authorized physical USB device by
  ADB. It does not expose the screen on the LAN and removes those forwards during clean shutdown.
- The runtime control socket is loopback-only and authenticated by a per-session token written to
  a `0600` control file. The runtime's socket is not inheritable by child processes, and a newer
  connection replaces the live one only after an authenticated `Hello`.
- Game audio is off unless `--audio-device` is passed. The name must resolve to one explicit
  CoreAudio input, and only that loopback device is captured; use `--route-audio` to temporarily
  direct application output to it and `--list-audio-devices` to audit the selection before
  streaming. Manager-launched sessions add the routing flag automatically.

## Tests

`swift test --package-path streamer` covers option parsing, AVCC→Annex-B conversion, ALVR
discovery/control/session packets, USB-device selection, UDP video, TCP video/uplink framing,
the runtime control protocol, and a live loopback round-trip through the local preview server.
It also covers HEVC parameter sets and packets, loss recovery on live VideoToolbox H.264 and HEVC
output (`frame_num` and reference picture sets), the reconnect supervisor, runtime connection
replacement, the idle filler, hand-tracking decode and gestures, and the `pipeline` statistics.
`scripts/check.zsh` also runs `scripts/test-quest-adb.zsh`, which checks the Quest serial choice
and the `play.zsh` Quest-log cleanup with a fake `adb`.
