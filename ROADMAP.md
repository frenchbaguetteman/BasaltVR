# BasaltVR roadmap

BasaltVR can be published as an experimental source project now. The items below are product and
consumer-release work, not blockers for making the repository public.

## Consumer-release gates

1. **Dependency provisioning**
   - Add an in-app, checksum-verified setup flow for the supported pinned Wine engine.
   - Keep third-party acquisition and redistribution license-compliant.
   - Provide progress, retry, rollback, disk-space checks, and actionable failure recovery.
2. **Apple distribution**
   - Sign every nested executable with Developer ID and the hardened runtime.
   - Notarize and staple the app or installer.
   - Add a documented uninstall path and a safe upgrade/migration test.
3. **Clean-machine acceptance**
   - Exercise first launch, permissions, setup, bottle creation, Steam login, OpenComposite
     installation, game launch, streaming, shutdown, and relaunch from a clean macOS user account.
   - Complete a managed Beat Saber session over USB and Wi-Fi from the GUI.
4. **Compatibility and recovery**
   - Publish a tested version matrix for macOS, Mac hardware, Quest/ALVR, Wine, Steam, Beat Saber,
     BSManager, and OpenComposite.
   - Verify recovery from headset sleep, ADB loss, Steam updates, game crashes, and interrupted
     setup without leaving routing, forwards, or Wine processes behind.

## Runtime and streaming work

- Expand application compatibility beyond the current Beat Saber/`hello_xr` boundary.
- Track OpenXR conformance gaps explicitly; the current runtime is intentionally non-conformant.
- Measure and decide the remaining IOSurface storage-mode performance tradeoff.
- Replace the current grip-as-aim fallback when ALVR exposes an independent aim pose.
- Evaluate foveated encoding and sustained thermal behavior at higher resolution/refresh profiles.
- Add longer soak, packet-loss, suspend/resume, and reconnect tests.

## Manager and project polish

- Add a guided first-run setup and dependency download UI.
- Add online metadata/artwork only with clear caching and privacy behavior.
- Add screenshots and a short hardware-identified demo to the README.
- Create the documented issue-label set when the repository is initialized.

## Explicitly out of scope for 0.1

- General PCVR compatibility claims.
- Microphone backhaul.
- Bundling games, store credentials, ALVR, OpenComposite, or other third-party applications.
- A signed/notarized consumer installer.
