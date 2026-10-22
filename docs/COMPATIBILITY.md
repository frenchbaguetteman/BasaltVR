# Compatibility

Results that were verified on real hardware. BasaltVR is an experimental developer preview: each
row is one user's result on one Mac and one headset, not a compatibility guarantee. To report a
result, see [SUPPORT.md](../SUPPORT.md).

## Verified

### Beat Saber and BSManager (M3 Max)

Steam Beat Saber and BSManager on an M3 Max, streaming to a Quest 3 with ALVR. This is the
project's original target; see the [README](../README.md) and [architecture](ARCHITECTURE.md).

### The Lab (M3 Pro)

| | |
|---|---|
| Mac | MacBook Pro, Apple M3 Pro, 18 GB, macOS 26.6.2 (Xcode 27.0 for the build) |
| Headset | Meta Quest 3, ALVR v20.14.1 client |
| Engine | Pinned Wine 11.10 with Basalt DXMT `v0.80-basalt.1` (DXMT v0.80 + patches 0001–0006) |
| OpenVR | OpenComposite built with `runtime/scripts/build-opencomposite.zsh` (patches 0001–0005), `default` preset, no proxy |
| Audio | BlackHole 2ch at 48 kHz |

All parts of Valve's The Lab (Steam app 450390) were played on the headset: the hub, Robot Repair
(Source 2, the Half-Life: Alyx engine), Secret Shop, and the other mini-games. Picture (no
flicker), head tracking, controllers, haptics, game audio, and Quest hand tracking with gestures
and switching between hands and controllers all worked.

| Link | Settings | Result |
|---|---|---|
| USB | `scripts/play.zsh the-lab` with `--quality high --codec hevc` (1344×1408 per eye, 60 Mbps, HEVC) | about 62 ms average latency, 10 ms Quest decode |
| USB | `--quality high --codec h264` | about 83 ms average latency, 26 ms Quest decode |
| USB | `--profile m3pro` (1152×1216 per eye, 30 Mbps) | about 71 fps, about 68 ms latency |
| Wi-Fi 6, 5 GHz | `scripts/play.zsh the-lab --wifi --quality high --codec hevc` with `BASALT_WIFI_MBPS=50` | about 68 fps at the Quest, about 83 ms latency, about 11 ms HEVC decode, 0 audio drops, 1 headset disconnect that recovered by itself |

Robot Repair rendered at about 35 fps over USB but felt smooth in the headset. Latency is the
Quest-reported input-to-display average. Game audio needs a terminal with Microphone permission;
see [the streamer guide](STREAMER.md#game-audio-over-blackhole).

### hello_xr (M3 Pro)

Khronos `hello_xr` (D3D11, `runtime/scripts/test-khr-hello-xr-headset.zsh`) on the same Mac and
headset over USB at 1152×1216 per eye, 12 Mbps, H.264: stereo picture, head tracking, and
controllers worked, at 72.0 fps and about 53 ms latency, with some small stutters; see
[performance](PERFORMANCE.md#known-issues).

## Not yet tested

- **Half-Life: Alyx** has not been tested on the M3 Pro (or any other Mac) with this setup. The
  OpenComposite patches, the OpenVR proxy, and the `alyx` preset target it, and Robot Repair runs
  on the same engine, but no Alyx session has been run.
- **Beat Saber** has not been tested on the M3 Pro; its profile was created but not launched there.
- Other Macs, other Quest models, and other games.

See [performance](PERFORMANCE.md) for settings and measurements and
[OpenComposite](OPENCOMPOSITE.md) for setting up OpenVR games.
