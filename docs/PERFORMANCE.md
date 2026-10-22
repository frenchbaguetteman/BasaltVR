# Performance and tuning

Settings, measurements, and diagnostics for streaming games to a Quest. The measurements come from
one MacBook Pro (M3 Pro, 18 GB, macOS 26.6.2) and one Quest 3 with the ALVR v20.14.1 client.
Other Macs will differ; compare one setting at a time from a cool headset.

## Recommended settings

`scripts/play.zsh` applies these defaults ([quality levels](BOTTLES.md#one-command-sessions)):

| Link | Default | Streamer settings |
|---|---|---|
| USB | `--quality high --codec hevc` | `--wired --profile m3pro --resolution quality --mbps 60 --codec hevc`: 1344×1408 per eye, 72 fps, 60 Mbps, low latency |
| Wi-Fi | `--quality normal --codec h264` | `--wireless --mbps 20 --codec h264`: 1344×1408 per eye, 72 fps, 20 Mbps (`BASALT_WIFI_MBPS` overrides) |

Why:

- HEVC over USB: in The Lab at 1344×1408 per eye, HEVC had 21 ms lower average latency than
  H.264 (62 ms against 83 ms), mostly from Quest decode time (10 ms against 26 ms), with no
  visible difference in sharpness or smoothness.
- H.264 over Wi-Fi by default: at low bitrates VideoToolbox's low-latency HEVC rate control drops
  more frames than H.264 (see [the benchmark](#encoder-benchmark)). A verified Wi-Fi 6 session ran
  HEVC at `--quality high` with `BASALT_WIFI_MBPS=50`; see [compatibility](COMPATIBILITY.md).
- At least 30 Mbps for games: with low-latency rate control, VideoToolbox drops whole frames
  (`kVTEncodeInfo_FrameDropped`) instead of lowering quality further when a frame does not fit the
  bitrate. Raising `MaxAllowedFrameQP` or removing `DataRateLimits` does not change this.
- Encoded size, not bitrate, limits the M3 Pro encoder. 1680×1760 per eye (`--quality max`) does
  not hold 72 fps with HEVC and is at the limit with H.264.

`--profile m3pro` (streamer) selects `balanced` (1152×1216 per eye), 72 fps, 30 Mbps, and low
latency; explicit `--fps`, `--mbps`, `--resolution`, and `--latency` win. It does not select a
codec.

## Measured results

| Setup | Content | Result |
|---|---|---|
| USB, 1344×1408, 60 Mbps, H.264 | The Lab | 83 ms average latency, 26 ms Quest decode |
| USB, 1344×1408, 60 Mbps, HEVC | The Lab | 62 ms average latency, 10 ms Quest decode |
| USB, `--profile m3pro` (1152×1216, 30 Mbps) | The Lab | about 71 fps, about 68 ms latency |
| USB | Robot Repair (Source 2) | about 35 fps rendered by the game; felt smooth in the headset |
| Wi-Fi 6 (5 GHz), 1344×1408, 50 Mbps, HEVC | all of The Lab | about 68 fps at the Quest, about 83 ms latency, about 11 ms HEVC decode, 0 audio drops, 1 headset disconnect that recovered by itself |
| USB, 1152×1216, 12 Mbps, H.264 | `hello_xr` | 72.0 fps and 52.7–52.9 ms latency between stalls (see [known issues](#known-issues)) |

Latency is the Quest-reported input-to-display average.

## Encoder benchmark

`basalt-streamer encoder-bench` runs the streamer's own encoder session (BGRA IOSurface input,
real-time pace, two frames in flight, IDR every 2 s) on synthetic, game-like content: a detailed
texture panning in two layers plus a moving object.

```sh
basalt-streamer encoder-bench [--codec h264|hevc|both] [--resolution balanced,quality,1680x1760] \
  [--mbps 30,60,80] [--fps 72] [--seconds 5] [--output-dir DIR]
```

M3 Pro, macOS 26.6.2, 72 fps, 360 frames per row, machine otherwise idle. Encode is
submit-to-output time; busy is frames skipped because both encoder slots were full (the
streamer's `encoder-busy`); no row had rate-control drops at 30–80 Mbps.

| Per eye (encoded) | Codec | Encode median / p95 at 30, 60, 80 Mbps (ms) | Busy frames |
|---|---|---|---|
| 1152×1216 (2304×1216) | H.264 | 8.8 / 9.8, 9.0 / 10.2, 9.1 / 10.2 | 4, 2, 3 |
| 1152×1216 (2304×1216) | HEVC | 8.8 / 10.6, 8.7 / 9.5, 9.5 / 10.5 | 1, 1, 1 |
| 1344×1408 (2688×1408) | H.264 | 10.5 / 11.8, 10.5 / 10.7, 10.5 / 10.9 | 2, 3, 3 |
| 1344×1408 (2688×1408) | HEVC | 11.5 / 12.3, 12.0 / 13.0, 11.8 / 12.9 | 1, 1, 1 |
| 1680×1760 (3360×1760) | H.264 | 16.6 / 21.7, 19.7 / 24.5, 18.7 / 24.7 | 2, 11, 12 |
| 1680×1760 (3360×1760) | HEVC | 23.5 / 28.3, 23.6 / 28.3, 23.5 / 28.4 | 52, 52, 58 |

The 1–4 busy frames in the smaller rows are the session start. A 72 Hz frame is 13.9 ms, so HEVC
at 1680×1760 skips about one frame in seven.

Rate-control drops at low bitrates (same content, out of 360 frames):

| Per eye | Codec | 8 Mbps | 12 Mbps | 20 Mbps |
|---|---|---|---|---|
| 1152×1216 | H.264 | 40 (11.9%) | 0 | 0 |
| 1152×1216 | HEVC | 92 (25.8%) | 0 | 0 |
| 1344×1408 | H.264 | 116 (32.5%) | 18 (5.3%) | 0 |
| 1344×1408 | HEVC | 146 (40.8%) | 47 (13.3%) | 0 |

So HEVC does not help a starved link; its gain is lower Quest decode time and possibly picture
quality at the same bitrate. Rate-control drops leave no `frame_num` gap (measured: 111 of 120
frames dropped, `frame_num` continuous), so they do not corrupt the picture chain.

## HEVC

`--codec hevc` (alias `h265`) sends HEVC the way ALVR v20.14.1's own servers do:

- **Stream:** Annex-B with 4-byte start codes. Each IDR access unit starts with VPS, SPS, and PPS
  (NAL types 32, 33, 34) read from the VideoToolbox format description. Keyframes are IDR
  pictures (NAL type 20), P-frames `TRAIL_R` (NAL type 1).
- **Decoder configuration:** a `DecoderConfig` control packet with `CodecType::Hevc` (1) and the
  VPS+SPS+PPS buffer, which the Quest passes to MediaCodec (`video/hevc`) as `csd-0`. The stream
  configuration also sets `video.preferred_codec`.
- **Profile:** HEVC Main (8-bit 4:2:0), hardware encoder required. Basalt's frames are 8-bit
  BGRA, so Main10 would add nothing. `--entropy` is rejected with HEVC (always CABAC).
- **Encoder:** the same low-latency session as H.264 (real-time, no frame reordering, the same
  bitrate, IDR, and forced-keyframe handling).
- **Loss recovery:** codec-agnostic; see [the streamer guide](STREAMER.md#loss-recovery).

Without a headset, `ffprobe`/`ffmpeg` decode the HEVC stream at all three sizes without errors,
and the local preview (`ffplay ... -f hevc`) decodes.

## Controller prediction

The ALVR client predicts the head for the measured pipeline latency, but predicts controllers
less by `steamvr_pipeline_frames` frames (default 3.0 in ALVR v20.11.1, 2.1 in v20.14.1), because
ALVR's own server lets SteamVR extrapolate the rest. Basalt passes controller poses through without
extrapolation, so with ALVR's default the controllers lagged the head by 2.1–3 frames (29–42 ms at
72 Hz). The streamer therefore sends `steamvr_pipeline_frames = 0` in the stream configuration
(`--controller-prediction full`, the default). `--controller-prediction alvr` restores ALVR's
behavior for comparison. Hand skeletons are not predicted; see [hand tracking](HAND-TRACKING.md).

## Settings reference

| Setting | Flag | Default | Notes |
|---|---|---|---|
| Per-eye resolution | `--resolution` | `quality` (1344×1408) | `performance` 896×944, `balanced` 1152×1216, or even custom sizes up to 1680×1760 with `--runtime`. The encoded frame is twice the width. |
| Bitrate | `--mbps` | 30 | 1–500. Fixed over USB. Over Wi-Fi an adaptive controller lowers it under congestion (20% steps, down to a third of `--mbps`, never below 8 Mbps). |
| Refresh rate | `--fps` | 72 | The streamer picks the advertised headset rate closest to it (the Quest 3 reports 72, 80, 90, 120 Hz); `xrWaitFrame` paces to that rate. |
| Codec | `--codec` | `h264` | H.264 High or HEVC Main |
| Entropy | `--entropy` | `cabac` | `cavlc` is ALVR's own default; same encode cost. H.264 only. |
| Periodic IDR | `--idr-interval` | 2 s | 1–60 s. Not needed for loss recovery; over USB it only costs a bitrate pulse (an IDR was about 2.4 times an average frame at 30 Mbps). |
| Decoder buffering | `--latency` | `low` | `balanced`, `low`, `ultra`; see [the streamer guide](STREAMER.md#latency-presets) |
| Controller prediction | `--controller-prediction` | `full` | `alvr` for comparison |
| Hand tracking | `--hand-tracking` | `on` | |
| Runtime frame window | — | 2 unconsumed frames | `xrWaitFrame` blocks on it |
| Pose freshness | — | 500 ms | Older head or controller samples are reported untracked |

Not implemented: foveated encoding (the ALVR client supports it, but Basalt has no encoder-side
warp yet), a cap on the video memory DXMT reports, and phase-locking `xrWaitFrame` to the Quest's
tracking cadence.

## Diagnostics

At startup the streamer prints `OpenXR frame pacing: <rate>` once a headset rate is negotiated and
`VideoToolbox ignored: ...` for encoder properties that the low-latency encoder refused (on
macOS 26: `MaxFrameDelayCount` and `PrioritizeEncodingSpeedOverQuality`, which therefore have no
effect).

Every 2 s in headset mode the streamer prints a `pipeline` line (format in
[the streamer guide](STREAMER.md#transport-behavior-and-diagnostics)):

| Field | Healthy | If not |
|---|---|---|
| `tracking N/s (max gap X ms, B backward)` | N ≈ 3 × refresh rate, X < 30 ms, B = 0 | X ≥ 500 ms: the Quest or the uplink stopped sending tracking. B > 0: Quest timestamps went backward and the runtime ignored those poses. |
| `runtime N/s (U untracked, R repeated pose)` | N ≈ refresh rate, U = 0, R ≈ 0 | U > 0: poses older than 500 ms. R > 0 with healthy tracking: poses did not reach the runtime. |
| `encoded N/s (A ms avg, M ms max)` | A within the frame budget | See [the benchmark](#encoder-benchmark) |
| `drops ...` | all 0 | `rate-control`: raise `--mbps`. `encoder-busy`/`compositor-busy`: GPU or encoder overload. `network-busy`: USB pauses, picture stays clean. `network`: each one costs a recovery IDR. `awaiting-IDR`: frames held until that IDR. |
| `pose age at send` | < 40 ms average | Frames wait in the Mac pipeline |

The Quest statistics line (`Quest ... fps; input→display latency: ... (decode D, decoder queue
Q, vsync V ms)`) gives the headset side; a decoder queue that grows over a session suggests clock
drift between the Mac and
the Quest.

Other sources:

- `scripts/play.zsh` saves the Quest's `adb logcat` for the whole session
  (`~/Library/Logs/BasaltVR/quest-<time>.log`; the Quest itself keeps only about 30 s). It starts
  at the session start (`-T 1`) and silences the `VideoRenderQualityTracker` tag. MediaCodec
  errors there mean the Quest could not decode the stream. Logs older than 7 days are deleted at
  the next session start (`BASALT_LOG_KEEP_DAYS`).
- `BASALT_RUNTIME_LOG` and `BASALT_HAPTIC_LOG=1`: see
  [runtime diagnostics](../runtime/README.md#runtime-diagnostics).
- A/B runs with `hello_xr`: `runtime/scripts/test-khr-hello-xr-headset.zsh` with
  `BASALT_HEADSET_MBPS`, `BASALT_HEADSET_FPS`, `BASALT_HEADSET_RESOLUTION`, and extra streamer flags
  in `BASALT_HEADSET_STREAMER_ARGS` (for example `'--codec hevc'` or `'--entropy cavlc'`).

## Known issues

- An earlier `hello_xr` run over USB (H.264, 12 Mbps, before the USB stall tolerance and loss
  recovery changes) showed a periodic pose stall: every ~10 s for 4–6 s, many frames reused the
  previous frame's tracking timestamp, displayed fps fell to 8–20, and latency peaked near 1 s.
  Encoder, USB write times, and bitrate were ruled out. It has not been re-measured since; the
  `pipeline` line's tracking gap and repeated-pose counts separate the possible causes.
- Quest H.264 decode stayed near 20 ms at both `balanced` and `quality` sizes, which suggests a
  fixed decoder hold rather than compute. HEVC decode was 10–11 ms in The Lab.

## Memory

On an 18 GB M3 Pro, Metal's `recommendedMaxWorkingSetSize` is 14.30 GB, and DXMT reports half of
it (about 7.15 GB) as the D3D11 adapter's dedicated video memory, which lives in the same unified
memory as everything else. Steam under Wine used about 3.2 GB RSS across seven Wine processes. The
pinned Wine 11.10 has no esync or msync, so `WINEESYNC`/`WINEMSYNC` do nothing. Close browsers and
other large apps before a session. To watch memory pressure during a session:

```sh
memory_pressure | tail -1
sysctl vm.swapusage
vm_stat 5
top -l 1 -o mem -n 15 -stats pid,command,mem
```
