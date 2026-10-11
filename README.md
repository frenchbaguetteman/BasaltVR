# BasaltVR

**A clean-room, open-source PCVR streaming stack for Apple Silicon Macs.** BasaltVR runs Windows
VR games under Wine and streams them to a Quest headset over ALVR.

[![CI](https://github.com/frenchbaguetteman/BasaltVR/actions/workflows/ci.yml/badge.svg)](https://github.com/frenchbaguetteman/BasaltVR/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/frenchbaguetteman/BasaltVR?include_prereleases&label=preview)](https://github.com/frenchbaguetteman/BasaltVR/releases)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%C2%B7%20Apple%20Silicon-lightgrey)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

*(Basalt is what molten rock becomes when it cools down and solidifies in the open.)*

> [!WARNING]
> BasaltVR is an experimental developer preview. Its OpenXR runtime is not conformant or
> game-ready in the general case. Beat Saber is the narrow compatibility target, and setup still
> requires developer tooling. Do not treat milestone passes as a broad compatibility guarantee.

**Tested with:** Steam Beat Saber and BSManager on an M3 Max, streaming to a Quest 3 with ALVR.

## How it works

```
Windows VR game ──► [OpenComposite] ──► Basalt OpenXR runtime ──► DXMT        (inside Wine)
 (D3D11, PE)         OpenVR games only    (Windows DLL)             (D3D11→Metal)
                                             │                        │
                              control socket │                        │ IOSurface per eye
                                             ▼                        ▼
                     basalt-streamer:  Metal stereo compose ──► VideoToolbox H.264   (native macOS)
                                             │
                                             ▼
                     ALVR transport (USB or Wi-Fi) ──► Quest headset
                     ◄── head/controller tracking, buttons, haptics, stats ──
```

BasaltVR reuses Wine, [DXMT](https://github.com/3Shain/dxmt),
[OpenComposite](https://gitlab.com/znixian/OpenOVR), and [ALVR](https://github.com/alvr-org/ALVR),
and builds the parts that were missing in the open: a Wine-facing OpenXR runtime, zero-copy Metal
composition and hardware encoding, the ALVR streamer bridge, isolated Wine bottle tooling, and a
SwiftUI manager that hides the setup behind a launch profile.

The project was developed clean-room from public behavior and open-source interfaces; no MoltenVR
source code was used. BasaltVR is independent and is not affiliated with or endorsed by MoltenVR,
Meta, Valve, Beat Games, or the upstream projects it interoperates with.

## Status

The first complete experience is intentionally narrow: launch a modded Windows build of
**Beat Saber** on an Apple Silicon Mac and play it on an ALVR headset with a few clicks. General
PCVR support comes after that vertical path works reliably.

| Milestone | Description | Status |
|-----------|-------------|--------|
| **M1** | Display capture → VideoToolbox H.264 (low-latency) → TCP stream | ✅ working |
| **M2** | ALVR transport bridge — stream to a real headset running the ALVR client | ✅ stable 72 fps over USB on Quest 3 |
| **M3** | OpenXR runtime: Windows PE ABI + native Metal compositor | ✅ D3D11 projection frames cross DXMT/IOSurface into the Swift streamer and reach the headset at 72 fps |
| **M4** | Tracking, controllers & haptics (ALVR input ↔ OpenXR actions) | ✅ automated HMD/Touch actions, spaces, velocity, loss/recovery, profiles, priority, and haptics pass; pinned Khronos `hello_xr` completes the external-app session path, and the live Quest gate is physically verified at 72 fps |
| **M5** | Wine bottle tooling: isolated DXMT engine, OpenXR registration, OpenComposite, launch profiles | ✅ CLI complete; disposable managed-bottle acceptance passes |
| **M6** | Audio (BlackHole) + USB streaming (adb) | ✅ 48 kHz stereo PCM reaches Quest over wired ALVR; live gate holds 1.536 Mbps with zero audio drops and audible headset output |
| **M7** | Management app: setup wizard, Steam/Whisky/CrossOver library, launcher | 🟨 preview packaging works; Developer ID/notarization and clean-user live acceptance remain |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design and what each milestone
involves, and [ROADMAP.md](ROADMAP.md) for the remaining consumer-release gates.

## Download

Download the latest Apple Silicon developer preview from
[GitHub Releases](../../releases). Each release includes a SHA-256 checksum and exact
limitations. The app requires macOS 14 or newer and is currently ad-hoc signed rather than
notarized.

Verify a downloaded archive before opening it:

```sh
shasum -a 256 -c BasaltVR-0.1.0-macos-arm64.zip.sha256
```

Extract the ZIP, move `BasaltVR.app` to Applications if desired, and use **Open** from Finder's
context menu on first launch. The app's **Setup** page reports missing runtime, Wine, ADB, and
optional audio prerequisites. This preview is intended for technical users; it is not yet a
turnkey installer.

For a complete setup, read the [management app guide](docs/MANAGEMENT.md) and
[bottle guide](docs/BOTTLES.md). The preview archive deliberately does not redistribute Wine,
ALVR, OpenComposite, BlackHole, games, or store credentials.

## The management app

The native SwiftUI app wraps the bottle and streaming tools. It checks the Mac and dependencies;
discovers Basalt, Whisky, and CrossOver bottles; reads installed Steam libraries and local artwork;
creates and edits launch profiles; owns streamer, Steam, installer, and game processes; and graphs
live Quest FPS, wire bitrate, and input-to-display latency.

The app writes only to Basalt's managed data root. External Whisky and CrossOver bottles are
read-only until you explicitly make an isolated APFS-cloned Basalt copy.

## Build from source

Requires an Apple Silicon Mac with macOS 14+ and the Xcode command-line tools. The Windows runtime
additionally needs `brew install cmake mingw-w64`.

```sh
make doctor          # check the local toolchain
make check           # the same quality gate CI runs
make app             # build everything and run the management app
```

| Command | What it does |
|---------|--------------|
| `make test` | Run the deterministic Swift test suite |
| `make runtime-build` | Cross-build the Windows OpenXR runtime DLL |
| `make runtime-test` | Run the Wine loader and ABI smoke suite |
| `make dxmt-test` | Run the pinned Wine 11.10 + DXMT graphics suite (needs Metal) |
| `make release VERSION=X.Y.Z` | Build a local preview archive |

Run `make help` for the full list, and see [CONTRIBUTING.md](CONTRIBUTING.md) before opening a
pull request.

## Repository layout

| Path | Contents |
|------|----------|
| [`streamer/`](streamer) | Swift package: `basalt-streamer` (encode + ALVR transport), `basaltctl` (bottles and profiles), and the `BasaltVR` manager app |
| [`runtime/`](runtime) | The Windows OpenXR runtime (C++, cross-built with MinGW), its Wine/DXMT test suites, and the Basalt DXMT fork patches |
| [`packaging/`](packaging) | App bundle and release archive tooling |
| [`scripts/`](scripts) | `doctor` and the `check` quality gate |
| [`docs/`](docs) | Design notes and user guides |

## Documentation

| Guide | Covers |
|-------|--------|
| [Management app](docs/MANAGEMENT.md) | Building, running, and the current GUI workflow |
| [Bottles and launch profiles](docs/BOTTLES.md) | `basaltctl`, isolated engines, OpenComposite, and launching games |
| [Streamer command line](docs/STREAMER.md) | `basalt-streamer` over USB and Wi-Fi, audio, stream settings, measurements, and security model |
| [OpenXR runtime](runtime/README.md) | What the runtime implements, how to build it, and its Wine, DXMT, and headset tests |
| [Architecture](docs/ARCHITECTURE.md) | System design, component map, and milestone history |
| [DXMT interop](docs/DXMT-INTEROP.md) | The D3D11 → Metal → IOSurface frame handoff and the Basalt DXMT fork |
| [Releasing](docs/RELEASING.md) and [maintaining](docs/MAINTAINING.md) | Preview releases, triage, and repository operations |

## Why this exists

MoltenVR is closed-source (binaries only, 7-day trial, license key via Patreon), yet most of
its stack is open source. The genuinely novel work — the OpenXR runtime and the glue — is
worth having in the open. That's this project.

## Contributing and support

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and pull-request expectations,
[SUPPORT.md](SUPPORT.md) for setup and compatibility-reporting help, and
[SECURITY.md](SECURITY.md) for private vulnerability reporting. Changes are recorded in
[CHANGELOG.md](CHANGELOG.md).

## License

BasaltVR code is available under the [MIT License](LICENSE). Components it orchestrates keep their
own licenses (ALVR: MIT; pinned DXMT v0.80: MIT; OpenComposite: GPLv3 — shipped as a separate
artifact, never linked in). See [third-party notices](THIRD_PARTY_NOTICES.md) for the distribution
boundary.
