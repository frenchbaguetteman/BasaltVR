import Foundation

/// Environment for BasaltVR.app when it is opened from Finder, Dock, or Spotlight: no
/// shell, so no BASALT_REPO_ROOT and only /usr/bin:/bin:/usr/sbin:/sbin on PATH.
///
/// Two bundle layouts (packaging/build-app.zsh writes both):
/// - Checkout-linked (`make app`): Info.plist key `BasaltRepoRoot` names the checkout
///   the app was built from. Scripts, `basalt-streamer`, `basaltctl`, the OpenXR runtime,
///   and the Steam web helper shim all come from that checkout, exactly as
///   `scripts/play.zsh` uses them from Terminal: one copy of each, nothing to drift.
/// - Self-contained (`make release`): `Contents/Resources/BasaltVR` holds the support
///   files (`BasaltVR.support.json`, runtime, scripts) and the tools sit beside the app.
public enum AppBundleEnvironment {
    public static let repoRootInfoKey = "BasaltRepoRoot"

    /// The variables to set before anything else runs. Empty when the app was started
    /// from a shell that already chose a repository.
    public static func overrides(
        bundleURL: URL, infoDictionary: [String: Any],
        environment: [String: String], fileManager: FileManager = .default
    ) -> [String: String] {
        var result = [String: String]()
        let searchPath = PlayLaunchPlan.searchPath(environment["PATH"])
        if searchPath != environment["PATH"] { result["PATH"] = searchPath }
        if let current = environment["BASALT_REPO_ROOT"], !current.isEmpty { return result }
        guard bundleURL.pathExtension == "app" else { return result }
        if let root = repoRoot(bundleURL: bundleURL, infoDictionary: infoDictionary,
                               fileManager: fileManager) {
            result["BASALT_REPO_ROOT"] = root.path
        }
        return result
    }

    public static func repoRoot(
        bundleURL: URL, infoDictionary: [String: Any], fileManager: FileManager = .default
    ) -> URL? {
        let support = bundleURL.appendingPathComponent(
            "Contents/Resources/BasaltVR", isDirectory: true)
        if fileManager.fileExists(
            atPath: support.appendingPathComponent("BasaltVR.support.json").path) {
            return support
        }
        if let path = infoDictionary[repoRootInfoKey] as? String, !path.isEmpty {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            if fileManager.fileExists(
                atPath: root.appendingPathComponent("streamer/Package.swift").path) {
                return root
            }
        }
        return nil
    }
}
