import Foundation

/// How a game reaches Basalt's OpenXR runtime.
public enum VRRuntimeKind: String, Codable, CaseIterable, Sendable {
    /// The game uses OpenXR itself. Basalt changes no game files.
    case openXR
    /// The game uses OpenVR (SteamVR). OpenComposite replaces its `openvr_api.dll`.
    case openVR
    /// Half-Life: Alyx. OpenComposite behind the Basalt proxy, with the `alyx` preset.
    case alyx

    public var label: String {
        switch self {
        case .openXR: return "Native OpenXR"
        case .openVR: return "OpenVR (OpenComposite)"
        case .alyx: return "Half-Life: Alyx (OpenComposite + proxy)"
        }
    }
}

/// The VR mode a person picks. `auto` follows detection when detection is sure.
public enum VRMode: String, Codable, CaseIterable, Sendable {
    case auto
    case openXR
    case openVR
    case alyx

    public var kind: VRRuntimeKind? {
        switch self {
        case .auto: return nil
        case .openXR: return .openXR
        case .openVR: return .openVR
        case .alyx: return .alyx
        }
    }
}

/// Where a game is installed, as host paths inside a bottle prefix.
public struct VRGameLocation: Equatable, Sendable {
    /// The game's own executable, when Basalt knows it (not `steam.exe`).
    public var executable: URL?
    /// The folder to search for VR files.
    public var folder: URL
    /// Steam app ID, when the game is a Steam game.
    public var steamAppID: String?

    public init(executable: URL?, folder: URL, steamAppID: String? = nil) {
        self.executable = executable?.standardizedFileURL
        self.folder = folder.standardizedFileURL
        self.steamAppID = steamAppID
    }
}

/// What Basalt found about one game's VR API. Detection is conservative: a DLL that only sits
/// near the game does not prove the game loads it.
public struct VRGameDetection: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// A known game with a fixed setup (Half-Life: Alyx).
        case knownAlyx
        /// The executable imports `openvr_api.dll`, or it is in this Unity game's plugins.
        case openVR
        /// The executable imports `openxr_loader.dll`, or it is in this Unity game's plugins.
        case openXR
        /// Evidence points both ways, or only to files the executable may not load.
        case uncertain
        /// No OpenVR or OpenXR file found.
        case nothingFound
    }

    public let verdict: Verdict
    /// Every `openvr_api.dll` found below the folder.
    public let openVRLibraries: [URL]
    /// The `openvr_api.dll` files the executable loads (strong evidence only).
    public let linkedOpenVRLibraries: [URL]
    /// Every `openxr_loader.dll` found below the folder.
    public let openXRLoaders: [URL]
    /// The search stopped at its file limit, so the lists may be incomplete.
    public let searchTruncated: Bool
    /// One plain sentence for the person.
    public let summary: String

    /// The kind to use in `auto` mode, or nil when the person must choose.
    public var suggestedKind: VRRuntimeKind? {
        switch verdict {
        case .knownAlyx: return .alyx
        case .openVR: return .openVR
        case .openXR: return .openXR
        case .uncertain, .nothingFound: return nil
        }
    }

    public func resolve(_ mode: VRMode) -> VRRuntimeKind? {
        mode.kind ?? suggestedKind
    }
}

public enum VRGameInspector {
    public static let alyxAppID = "546560"
    static let maximumEntries = 40_000
    static let maximumDepth = 10

    public static func isAlyx(_ location: VRGameLocation) -> Bool {
        location.steamAppID == alyxAppID
            || location.executable?.lastPathComponent.lowercased() == "hlvr.exe"
    }

    /// Searches `location.folder` without following symbolic links.
    public static func inspect(_ location: VRGameLocation,
                               fileManager: FileManager = .default) -> VRGameDetection {
        if isAlyx(location) {
            return VRGameDetection(
                verdict: .knownAlyx, openVRLibraries: [], linkedOpenVRLibraries: [],
                openXRLoaders: [], searchTruncated: false,
                summary: "Half-Life: Alyx uses OpenVR. Basalt installs OpenComposite behind its proxy in game/bin/win64.")
        }
        var openVR = [URL]()
        var openXR = [URL]()
        var truncated = false
        let root = location.folder
        if let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]) {
            var count = 0
            for case let url as URL in enumerator {
                count += 1
                if count > maximumEntries {
                    truncated = true
                    break
                }
                if enumerator.level > maximumDepth {
                    enumerator.skipDescendants()
                    continue
                }
                let name = url.lastPathComponent.lowercased()
                guard name == "openvr_api.dll" || name == "openxr_loader.dll" else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
                if name == "openvr_api.dll" {
                    openVR.append(url.standardizedFileURL)
                } else {
                    openXR.append(url.standardizedFileURL)
                }
            }
        }
        openVR.sort { $0.path < $1.path }
        openXR.sort { $0.path < $1.path }

        var imports = Set<String>()
        if let executable = location.executable,
           let bytes = try? Data(contentsOf: executable, options: .alwaysMapped) {
            imports = PEImage.importedLibraries(bytes)
        }
        let executableImportsOpenVR = imports.contains("openvr_api.dll")
        let executableImportsOpenXR = imports.contains("openxr_loader.dll")
        let linkedOpenVR = openVR.filter { isLinked($0, to: location.executable, imports: executableImportsOpenVR) }
        let linkedOpenXR = openXR.filter { isLinked($0, to: location.executable, imports: executableImportsOpenXR) }
        let usesOpenVR = !linkedOpenVR.isEmpty || executableImportsOpenVR
        let usesOpenXR = !linkedOpenXR.isEmpty || executableImportsOpenXR
        let exeName = location.executable?.lastPathComponent ?? "the game"

        let verdict: VRGameDetection.Verdict
        let summary: String
        if usesOpenVR && usesOpenXR {
            verdict = .uncertain
            summary = "\(exeName) ships both OpenVR and OpenXR files. Choose the mode the game uses."
        } else if usesOpenVR {
            if linkedOpenVR.isEmpty {
                verdict = .uncertain
                summary = "\(exeName) imports openvr_api.dll, but there is no copy beside it. Choose a mode."
            } else {
                verdict = .openVR
                summary = "\(exeName) loads openvr_api.dll (OpenVR). Basalt installs OpenComposite."
            }
        } else if usesOpenXR {
            verdict = .openXR
            summary = "\(exeName) loads the OpenXR loader. It is a native OpenXR game: no files change."
        } else if !openVR.isEmpty || !openXR.isEmpty {
            verdict = .uncertain
            let count = openVR.count + openXR.count
            summary = "Found \(count == 1 ? "a VR file" : "\(count) VR files") in the game folder, but Basalt cannot tell if \(exeName) loads \(count == 1 ? "it" : "them"). Choose a mode."
        } else {
            verdict = .nothingFound
            summary = truncated
                ? "The game folder is too large to search fully, and no VR file was found. Choose a mode."
                : "No OpenVR or OpenXR file found. The game may be native OpenXR or not a VR game."
        }
        return VRGameDetection(
            verdict: verdict, openVRLibraries: openVR, linkedOpenVRLibraries: linkedOpenVR,
            openXRLoaders: openXR, searchTruncated: truncated, summary: summary)
    }

    /// A DLL counts as loaded by the executable when it is in this Unity player's plugin folder
    /// (`<Exe>_Data/Plugins`), or when it sits beside an executable that imports it.
    static func isLinked(_ library: URL, to executable: URL?, imports: Bool) -> Bool {
        guard let executable else { return false }
        let directory = executable.deletingLastPathComponent().standardizedFileURL
        if imports, library.deletingLastPathComponent().standardizedFileURL == directory {
            return true
        }
        let plugins = directory
            .appendingPathComponent(executable.deletingPathExtension().lastPathComponent + "_Data")
            .appendingPathComponent("Plugins").standardizedFileURL
        return library.path.lowercased().hasPrefix(plugins.path.lowercased() + "/")
    }
}
