# Releasing BasaltVR

BasaltVR releases are explicitly labeled developer previews until the app is Developer ID-signed,
notarized, and accepted from a clean macOS user account with a live headset.

## Before tagging

1. Update `CHANGELOG.md` and `docs/releases/vX.Y.Z.md`. The packager writes the requested version
   into `Info.plist` and refuses to build when either release document is missing.
2. Run:

   ```sh
   make doctor-dxmt
   make check
   make runtime-test
   make dxmt-test
   make release VERSION=X.Y.Z
   ```

3. Verify the generated archive:

   ```sh
   cd release
   shasum -a 256 -c BasaltVR-X.Y.Z-macos-arm64.zip.sha256
   unzip -t BasaltVR-X.Y.Z-macos-arm64.zip
   ```

4. Confirm the app and all bundled native executables are arm64, the app's internal signature
   verifies, and the support manifest records `wineIncluded` as `false`.
5. Extract the ZIP into a clean temporary directory and run the bundled CLI outside the source
   checkout:

   ```sh
   /path/to/BasaltVR.app/Contents/MacOS/basaltctl doctor
   ```

6. Sanitize release notes and logs. Never publish account names, home-directory paths, ADB serials,
   Steam credentials, game files, or captured content.

## Publishing

Push an annotated `vX.Y.Z` tag. The release workflow rebuilds the pinned Basalt DXMT fork, verifies
the generated PE/Mach-O architectures and macOS deployment target, runs Swift tests, creates the
archive and checksum, and publishes a GitHub prerelease using `docs/releases/vX.Y.Z.md`.

GitHub's virtual macOS runners do not expose the physical Metal/IOSurface sharing needed by
`make dxmt-test`. That full graphics and cross-process pixel gate remains mandatory on a physical
Apple Silicon Mac before tagging; the hosted workflow performs deterministic source, build, and
artifact verification without weakening the local release gate.

The workflow uses the repository-scoped `GITHUB_TOKEN` with only `contents: write`. No Apple
signing credentials are required for the current ad-hoc-signed preview. It refuses to overwrite
an existing GitHub release; publish a new version for any corrected artifact.

Release builds run on a pinned Apple Silicon runner image while the native build and DXMT fork
explicitly preserve the macOS 14 deployment target. Workflow actions are pinned to immutable
commits and updated through Dependabot.

After publishing, download the assets from GitHub rather than reusing local files, verify the
checksum and signature again, and confirm the release notes and "latest release" link render
correctly.

## Consumer-release gates

A non-preview release additionally requires:

- an Apple Developer ID Application certificate and hardened-runtime signing;
- notarization and stapling;
- an audited installation/update path for the pinned Wine engine that satisfies all third-party
  redistribution obligations;
- clean-user-account setup and upgrade tests;
- a live managed Beat Saber launch through the GUI;
- rollback and uninstall documentation.
