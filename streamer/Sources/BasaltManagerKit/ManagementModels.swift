import Foundation
import CoreGraphics
import BasaltBottleKit
import BasaltCore

public enum SetupCheckStatus: String, Sendable {
    case ready
    case actionNeeded
    case unavailable
}

public struct SetupCheck: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let status: SetupCheckStatus
    public let required: Bool
    public let action: String?

    public init(id: String, title: String, detail: String,
                status: SetupCheckStatus, required: Bool, action: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.required = required
        self.action = action
    }
}

public struct SetupInspector: @unchecked Sendable {
    public let repoRoot: URL
    public let manager: BottleManager
    private let fileManager: FileManager

    public init(repoRoot: URL, manager: BottleManager,
                fileManager: FileManager = .default) {
        self.repoRoot = repoRoot
        self.manager = manager
        self.fileManager = fileManager
    }

    public func inspect() -> [SetupCheck] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let supportedOS = version.majorVersion >= 14
        let arm = ProcessInfo.processInfo.machineHardwareName == "arm64"
        let engines = manager.engines()
        let pinnedEngine = engines.contains { $0.kind == .pinned && $0.supportsBasaltDXMT }
        let runtime = repoRoot.appendingPathComponent("runtime/build/bin/basalt_openxr.dll")
        let dxmt = repoRoot.appendingPathComponent(
            "runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so")
        let adb = Self.findExecutable(named: "adb", fileManager: fileManager)
        let audioNames = (try? GameAudioDeviceDiscovery.inputDevices().map(\.name)) ?? []
        let hasBlackHole = audioNames.contains {
            $0.localizedCaseInsensitiveContains("BlackHole")
        }

        return [
            SetupCheck(
                id: "mac", title: "Apple Silicon Mac",
                detail: arm && supportedOS
                    ? "Apple Silicon and macOS 14 or newer"
                    : "BasaltVR requires Apple Silicon and macOS 14 or newer",
                status: arm && supportedOS ? .ready : .unavailable, required: true),
            SetupCheck(
                id: "screen", title: "Screen Recording",
                detail: CGPreflightScreenCaptureAccess()
                    ? "Permission granted"
                    : "Needed for the desktop preview; runtime game streaming does not capture other apps",
                status: CGPreflightScreenCaptureAccess() ? .ready : .actionNeeded,
                required: false, action: "Grant Permission"),
            SetupCheck(
                id: "adb", title: "Android Platform Tools",
                detail: adb?.path ?? "Optional for wireless; required only for USB cable streaming",
                status: adb == nil ? .actionNeeded : .ready,
                required: false, action: "Install with Homebrew"),
            SetupCheck(
                id: "wine", title: "Pinned Wine + DXMT engine",
                detail: pinnedEngine ? "Verified engine is available" : "Build the pinned M5 engine and Basalt DXMT fork",
                status: pinnedEngine ? .ready : .actionNeeded,
                required: true, action: "Open Build Instructions"),
            SetupCheck(
                id: "runtime", title: "OpenXR runtime",
                detail: fileManager.fileExists(atPath: runtime.path)
                    ? runtime.path : "The Windows OpenXR runtime has not been built",
                status: fileManager.fileExists(atPath: runtime.path) ? .ready : .actionNeeded,
                required: true, action: "Open Build Instructions"),
            SetupCheck(
                id: "dxmt", title: "Basalt DXMT handoff",
                detail: fileManager.fileExists(atPath: dxmt.path)
                    ? dxmt.path : "The IOSurface-enabled DXMT fork has not been built",
                status: fileManager.fileExists(atPath: dxmt.path) ? .ready : .actionNeeded,
                required: true, action: "Open Build Instructions"),
            SetupCheck(
                id: "audio", title: "BlackHole game audio",
                detail: hasBlackHole
                    ? "\(audioNames.first { $0.localizedCaseInsensitiveContains("BlackHole") } ?? "BlackHole") is available"
                    : "Optional 48 kHz loopback device for headset audio",
                status: hasBlackHole ? .ready : .actionNeeded,
                required: false, action: "Install with Homebrew"),
        ]
    }

    public static func findExecutable(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let search = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in search {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}

public struct DetectedGame: Identifiable, Equatable, Sendable {
    public var id: String { bottleName + "|" + executable }
    public let title: String
    public let bottleName: String
    public let source: LaunchSource
    public let executable: String
    public let hostExecutable: URL?
    public let profileName: String?

    public init(title: String, bottleName: String, source: LaunchSource,
                executable: String, hostExecutable: URL?, profileName: String?) {
        self.title = title
        self.bottleName = bottleName
        self.source = source
        self.executable = executable
        self.hostExecutable = hostExecutable
        self.profileName = profileName
    }
}

public struct BSManagerInstance: Identifiable, Equatable, Sendable {
    public var id: String { executable.standardizedFileURL.path }
    public let name: String
    public let version: String
    public let directory: URL
    public let executable: URL
    public let installationDirectory: URL
    public let isModded: Bool
    public let metadataID: String?
    public let store: String?
    public let bottleName: String?

    public init(name: String, version: String, directory: URL, executable: URL,
                installationDirectory: URL, isModded: Bool,
                metadataID: String? = nil, store: String? = nil,
                bottleName: String? = nil) {
        self.name = name
        self.version = version
        self.directory = directory.standardizedFileURL
        self.executable = executable.standardizedFileURL
        self.installationDirectory = installationDirectory.standardizedFileURL
        self.isModded = isModded
        self.metadataID = metadataID
        self.store = store
        self.bottleName = bottleName
    }
}

public struct BSManagerInstallation: Identifiable, Equatable, Sendable {
    public var id: String { bottleName + "|" + executable.standardizedFileURL.path }
    public let bottleName: String
    public let executable: URL

    public init(bottleName: String, executable: URL) {
        self.bottleName = bottleName
        self.executable = executable.standardizedFileURL
    }
}

/// Discovers BSManager-managed Beat Saber versions without modifying them.
///
/// BSManager stores versions one directory below `BSManager/BSInstances`. Its
/// `installation-folder` preference is the parent of `BSManager`, not the
/// `BSManager` directory itself. Explicit locations are deliberately flexible
/// so a user can select the parent, `BSManager`, `BSInstances`, or one instance.
public struct BSManagerDiscovery: @unchecked Sendable {
    private let home: URL
    private let fileManager: FileManager

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                fileManager: FileManager = .default) {
        self.home = home.standardizedFileURL
        self.fileManager = fileManager
    }

    public func discover(
        additionalLocations: [URL] = [],
        bottles: [ManagedBottle] = []
    ) -> [BSManagerInstance] {
        var locations = additionalLocations
        locations += [
            home.appendingPathComponent("BSManager", isDirectory: true),
            home.appendingPathComponent("Documents/BSManager", isDirectory: true),
        ]
        locations += configuredInstallationParents().map {
            $0.appendingPathComponent("BSManager", isDirectory: true)
        }

        var instances = [String: BSManagerInstance]()
        for location in unique(locations) {
            for directory in instanceDirectories(at: location) {
                guard let instance = instance(
                    at: directory, selectedLocation: location, bottleName: nil)
                else { continue }
                instances[instance.id] = instance
            }
        }
        for bottle in bottles {
            let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            for home in Self.windowsUserHomes(in: prefix, fileManager: fileManager) {
                let location = home.appendingPathComponent("BSManager", isDirectory: true)
                for directory in instanceDirectories(at: location) {
                    guard let instance = instance(
                        at: directory, selectedLocation: location,
                        bottleName: bottle.name) else { continue }
                    instances[instance.id] = instance
                }
            }
        }
        return instances.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func configuredInstallationParents() -> [URL] {
        let applicationSupport = home.appendingPathComponent(
            "Library/Application Support", isDirectory: true)
        let configFiles = [
            applicationSupport.appendingPathComponent("BSManager/config.json"),
            applicationSupport.appendingPathComponent("bs-manager/config.json"),
            applicationSupport.appendingPathComponent("io.bsmanager.bsmanager/config.json"),
        ]
        return configFiles.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let path = object["installation-folder"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    private func instanceDirectories(at selectedLocation: URL) -> [URL] {
        let selected = selectedLocation.standardizedFileURL
        if hasBeatSaberExecutable(selected) { return [selected] }

        let versions: URL
        if selected.lastPathComponent.caseInsensitiveCompare("BSInstances") == .orderedSame {
            versions = selected
        } else if fileManager.fileExists(
            atPath: selected.appendingPathComponent("BSInstances").path) {
            versions = selected.appendingPathComponent("BSInstances", isDirectory: true)
        } else {
            versions = selected.appendingPathComponent(
                "BSManager/BSInstances", isDirectory: true)
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: versions, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return children.filter(hasBeatSaberExecutable)
    }

    private func hasBeatSaberExecutable(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let executable = directory.appendingPathComponent("Beat Saber.exe")
        return fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.fileExists(atPath: executable.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func instance(
        at directory: URL, selectedLocation: URL, bottleName: String?
    )
        -> BSManagerInstance? {
        guard hasBeatSaberExecutable(directory) else { return nil }
        let executable = directory.appendingPathComponent("Beat Saber.exe")
        let folderName = directory.lastPathComponent
        let metadata = metadata(at: directory.appendingPathComponent("metadata.config"))
        let installation: URL
        if let versions = ancestor(named: "BSInstances", from: directory) {
            installation = versions.deletingLastPathComponent()
        } else {
            installation = selectedLocation
        }
        let plugins = directory.appendingPathComponent("Plugins", isDirectory: true)
        let isModded = fileManager.fileExists(
            atPath: directory.appendingPathComponent("IPA.exe").path)
            || ((try? fileManager.contentsOfDirectory(
                at: plugins, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]).isEmpty) == false)
        return BSManagerInstance(
            name: folderName, version: folderName, directory: directory,
            executable: executable, installationDirectory: installation,
            isModded: isModded, metadataID: metadata.id, store: metadata.store,
            bottleName: bottleName)
    }

    private func metadata(at file: URL) -> (id: String?, store: String?) {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return (nil, nil) }
        let store: String?
        if let value = object["store"] as? String {
            store = value
        } else if let value = object["store"] as? NSNumber {
            store = value.stringValue
        } else {
            store = nil
        }
        return (object["id"] as? String, store)
    }

    private func ancestor(named name: String, from url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if candidate.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private func unique(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        return values.map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
    }

    fileprivate static func windowsUserHomes(
        in prefix: URL, fileManager: FileManager
    ) -> [URL] {
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        guard let homes = try? fileManager.contentsOfDirectory(
            at: users, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return homes.filter {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}

/// Finds the Windows BSManager application installed in each managed bottle.
/// The NSIS installer normally uses LocalAppData, while the Program Files
/// candidates support portable and manually selected installations.
public struct BSManagerInstallationDiscovery: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func discover(in bottles: [ManagedBottle]) -> [BSManagerInstallation] {
        var installations = [String: BSManagerInstallation]()
        for bottle in bottles {
            let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            var candidates = [
                prefix.appendingPathComponent(
                    "drive_c/Program Files/BSManager/BSManager.exe"),
                prefix.appendingPathComponent(
                    "drive_c/Program Files/bs-manager/BSManager.exe"),
                prefix.appendingPathComponent(
                    "drive_c/Program Files (x86)/BSManager/BSManager.exe"),
                prefix.appendingPathComponent(
                    "drive_c/Program Files (x86)/bs-manager/BSManager.exe"),
            ]
            for home in BSManagerDiscovery.windowsUserHomes(
                in: prefix, fileManager: fileManager) {
                candidates += [
                    home.appendingPathComponent(
                        "AppData/Local/Programs/bs-manager/BSManager.exe"),
                    home.appendingPathComponent(
                        "AppData/Local/Programs/BSManager/BSManager.exe"),
                ]
            }
            if let executable = candidates.first(where: isExecutableFile) {
                let installation = BSManagerInstallation(
                    bottleName: bottle.name, executable: executable)
                installations[installation.id] = installation
            }
        }
        return installations.values.sorted {
            $0.bottleName.localizedStandardCompare($1.bottleName) == .orderedAscending
        }
    }

    private func isExecutableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

public struct GameDetector: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func detect(bottles: [ManagedBottle], profiles: [LaunchProfile]) -> [DetectedGame] {
        var games = [String: DetectedGame]()
        let bottlesByName = Dictionary(uniqueKeysWithValues: bottles.map { ($0.name, $0) })

        for profile in profiles {
            guard let bottle = bottlesByName[profile.bottleName] else { continue }
            let host = Self.hostURL(for: profile.executable, bottle: bottle)
            let title = Self.gameTitle(profile: profile)
            let game = DetectedGame(
                title: title, bottleName: bottle.name, source: profile.source,
                executable: profile.executable, hostExecutable: host,
                profileName: profile.name)
            games[game.id.lowercased()] = game
        }

        for bottle in bottles {
            let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
                .standardizedFileURL
            let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: driveC,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }

            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > 100_000 { break }
                if ["windows", "$recycle.bin"].contains(url.lastPathComponent.lowercased()) {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.lastPathComponent.caseInsensitiveCompare("Beat Saber.exe") == .orderedSame
                else { continue }
                let resolved = url.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(prefix.resolvingSymlinksInPath().path + "/") else {
                    continue
                }
                let windowsPath = BottleManager.winePath(for: url, prefix: prefix)
                let key = (bottle.name + "|" + windowsPath).lowercased()
                guard games[key] == nil else { continue }
                games[key] = DetectedGame(
                    title: "Beat Saber", bottleName: bottle.name,
                    source: Self.inferSource(from: url.path), executable: windowsPath,
                    hostExecutable: url.standardizedFileURL, profileName: nil)
            }
        }

        let detected = games.values.filter { candidate in
            guard candidate.profileName == nil else { return true }
            return !games.values.contains {
                $0.profileName != nil && $0.bottleName == candidate.bottleName
                    && $0.title.caseInsensitiveCompare(candidate.title) == .orderedSame
            }
        }
        return detected.sorted {
            if $0.title != $1.title {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.bottleName.localizedStandardCompare($1.bottleName) == .orderedAscending
        }
    }

    public static func hostURL(for windowsPath: String, bottle: ManagedBottle) -> URL? {
        let normalized = windowsPath.replacingOccurrences(of: "\\", with: "/")
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        if normalized.lowercased().hasPrefix("c:/") {
            return prefix.appendingPathComponent("drive_c")
                .appendingPathComponent(String(normalized.dropFirst(3))).standardizedFileURL
        }
        if normalized.lowercased().hasPrefix("z:/") {
            return URL(fileURLWithPath: "/" + String(normalized.dropFirst(3))).standardizedFileURL
        }
        return nil
    }

    private static func inferSource(from path: String) -> LaunchSource {
        let lower = path.lowercased()
        if lower.contains("bsmanager") || lower.contains("bsinstances") { return .bsmanager }
        if lower.contains("itch") { return .itch }
        if lower.contains("steam") { return .steam }
        return .direct
    }

    private static func gameTitle(profile: LaunchProfile) -> String {
        let normalizedName = profile.name.lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if normalizedName.contains("beat-saber")
            || profile.executable.localizedCaseInsensitiveContains("Beat Saber")
            || profile.arguments.contains("620980") {
            return "Beat Saber"
        }
        let filename = profile.executable.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map(String.init) ?? profile.name
        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? profile.name : stem
    }
}

public enum BottleOrigin: String, Codable, CaseIterable, Sendable {
    case managed
    case whisky
    case crossover

    public var label: String {
        switch self {
        case .managed: return "Basalt"
        case .whisky: return "Whisky"
        case .crossover: return "CrossOver"
        }
    }
}

public struct DiscoveredBottle: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let origin: BottleOrigin
    public let prefix: URL
    public let managed: ManagedBottle?

    public init(name: String, origin: BottleOrigin, prefix: URL,
                managed: ManagedBottle? = nil) {
        self.name = name
        self.origin = origin
        self.prefix = prefix.standardizedFileURL
        self.managed = managed
        id = origin.rawValue + ":" + self.prefix.path
    }

    public var isManaged: Bool { managed != nil }
    public var isReadyForVR: Bool { managed?.isReadyForVR == true }
}

public struct ExternalBottleDiscovery: @unchecked Sendable {
    private let home: URL
    private let fileManager: FileManager

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                fileManager: FileManager = .default) {
        self.home = home
        self.fileManager = fileManager
    }

    public func discover(managed: [ManagedBottle] = []) -> [DiscoveredBottle] {
        var result = managed.map {
            DiscoveredBottle(
                name: $0.name, origin: .managed,
                prefix: URL(fileURLWithPath: $0.prefixPath, isDirectory: true),
                managed: $0)
        }
        result += whiskyBottles()
        result += crossoverBottles()
        return result.sorted {
            if $0.origin != $1.origin { return $0.origin.rawValue < $1.origin.rawValue }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func whiskyBottles() -> [DiscoveredBottle] {
        let root = home.appendingPathComponent(
            "Library/Containers/com.isaacmarovitz.Whisky/Bottles", isDirectory: true)
        return bottleDirectories(at: root).map { directory in
            let metadata = directory.appendingPathComponent("Metadata.plist")
            let name = whiskyName(from: metadata) ?? directory.lastPathComponent
            return DiscoveredBottle(
                name: name, origin: .whisky, prefix: directory)
        }
    }

    private func crossoverBottles() -> [DiscoveredBottle] {
        let root = home.appendingPathComponent(
            "Library/Application Support/CrossOver/Bottles", isDirectory: true)
        return bottleDirectories(at: root).map {
            DiscoveredBottle(name: $0.lastPathComponent, origin: .crossover, prefix: $0)
        }
    }

    private func bottleDirectories(at root: URL) -> [URL] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return directories.filter {
            fileManager.fileExists(atPath: $0.appendingPathComponent("drive_c").path)
                && fileManager.fileExists(atPath: $0.appendingPathComponent("system.reg").path)
        }
    }

    private func whiskyName(from metadata: URL) -> String? {
        guard let data = try? Data(contentsOf: metadata),
              let object = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let info = object["info"] as? [String: Any],
              let name = info["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }
}

public struct SteamGame: Identifiable, Equatable, Sendable {
    public var id: String { bottleID + ":steam:" + appID }
    public let appID: String
    public let name: String
    public let bottleID: String
    public let bottleName: String
    public let bottleOrigin: BottleOrigin
    public let installDirectory: URL
    public let steamExecutable: URL
    public let artwork: URL?
    public let sizeOnDisk: Int64?
    public let lastPlayed: Date?

    public init(appID: String, name: String, bottle: DiscoveredBottle,
                installDirectory: URL, steamExecutable: URL, artwork: URL?,
                sizeOnDisk: Int64?, lastPlayed: Date?) {
        self.appID = appID
        self.name = name
        bottleID = bottle.id
        bottleName = bottle.name
        bottleOrigin = bottle.origin
        self.installDirectory = installDirectory.standardizedFileURL
        self.steamExecutable = steamExecutable.standardizedFileURL
        self.artwork = artwork?.standardizedFileURL
        self.sizeOnDisk = sizeOnDisk
        self.lastPlayed = lastPlayed
    }

    public var isKnownVRGame: Bool {
        ["250820", "620980", "739630"].contains(appID)
    }

    public var isTool: Bool {
        ["228980", "250820"].contains(appID)
            || name.localizedCaseInsensitiveContains("Redistributable")
    }
}

public struct SteamLibraryDiscovery: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func discover(in bottles: [DiscoveredBottle]) -> [SteamGame] {
        bottles.flatMap(discover(in:)).sorted {
            if $0.name != $1.name {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.bottleName.localizedStandardCompare($1.bottleName) == .orderedAscending
        }
    }

    public func discover(in bottle: DiscoveredBottle) -> [SteamGame] {
        let roots = steamRoots(in: bottle.prefix)
        var games = [String: SteamGame]()
        for steamRoot in roots {
            let executable = steamRoot.appendingPathComponent("steam.exe")
            guard fileManager.fileExists(atPath: executable.path) else { continue }
            var steamApps = [steamRoot.appendingPathComponent("steamapps", isDirectory: true)]
            let libraries = steamApps[0].appendingPathComponent("libraryfolders.vdf")
            if let value = try? String(contentsOf: libraries, encoding: .utf8) {
                for path in Self.values(for: "path", in: value) {
                    if let root = hostURL(forWindowsPath: path, prefix: bottle.prefix) {
                        steamApps.append(root.appendingPathComponent("steamapps", isDirectory: true))
                    }
                }
            }

            for folder in unique(steamApps) {
                guard let manifests = try? fileManager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]) else { continue }
                for manifest in manifests where
                    manifest.lastPathComponent.hasPrefix("appmanifest_")
                        && manifest.pathExtension.lowercased() == "acf" {
                    guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                          let appID = Self.value(for: "appid", in: text),
                          let name = Self.value(for: "name", in: text),
                          let installName = Self.value(for: "installdir", in: text) else { continue }
                    let install = folder.appendingPathComponent("common", isDirectory: true)
                        .appendingPathComponent(installName, isDirectory: true)
                    guard fileManager.fileExists(atPath: install.path) else { continue }
                    let size = Self.value(for: "SizeOnDisk", in: text).flatMap(Int64.init)
                    let played = Self.value(for: "LastPlayed", in: text)
                        .flatMap(TimeInterval.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                    games[bottle.id + ":" + appID] = SteamGame(
                        appID: appID, name: name, bottle: bottle,
                        installDirectory: install, steamExecutable: executable,
                        artwork: artworkURL(appID: appID, steamRoot: steamRoot),
                        sizeOnDisk: size, lastPlayed: played)
                }
            }
        }
        return Array(games.values)
    }

    public static func value(for key: String, in vdf: String) -> String? {
        values(for: key, in: vdf).first
    }

    public static func values(for key: String, in vdf: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let expression = try? NSRegularExpression(
            pattern: #"\""# + escaped + #"\"\s*\"((?:\\.|[^\"])*)\""#,
            options: [.caseInsensitive]) else { return [] }
        return expression.matches(
            in: vdf, range: NSRange(vdf.startIndex..., in: vdf)).compactMap { match in
                guard let range = Range(match.range(at: 1), in: vdf) else { return nil }
                return String(vdf[range])
                    .replacingOccurrences(of: #"\\"#, with: #"\"#)
                    .replacingOccurrences(of: #"\""#, with: #"""#)
            }
    }

    private func steamRoots(in prefix: URL) -> [URL] {
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        return [
            driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true),
            driveC.appendingPathComponent("Program Files/Steam", isDirectory: true),
        ]
    }

    private func hostURL(forWindowsPath path: String, prefix: URL) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 3,
              let drive = normalized.first?.lowercased(),
              normalized.dropFirst().hasPrefix(":/") else { return nil }
        if drive == "c" {
            return prefix.appendingPathComponent("drive_c", isDirectory: true)
                .appendingPathComponent(String(normalized.dropFirst(3)), isDirectory: true)
        }
        let link = prefix.appendingPathComponent("dosdevices/\(drive):")
        guard fileManager.fileExists(atPath: link.path) else { return nil }
        return link.resolvingSymlinksInPath()
            .appendingPathComponent(String(normalized.dropFirst(3)), isDirectory: true)
    }

    private func artworkURL(appID: String, steamRoot: URL) -> URL? {
        let root = steamRoot.appendingPathComponent("appcache/librarycache/\(appID)")
        for name in ["library_600x900.jpg", "header.jpg", "library_header.jpg"] {
            let candidate = root.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in enumerator {
            if ["library_600x900.jpg", "header.jpg", "library_header.jpg"]
                .contains(url.lastPathComponent.lowercased()) { return url }
        }
        return nil
    }

    private func unique(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

public enum ResolutionSelection: String, Codable, CaseIterable, Sendable {
    case performance
    case balanced
    case quality

    /// The per-eye size `basalt-streamer --resolution <rawValue>` uses.
    public var perEyeResolution: PerEyeResolution {
        switch self {
        case .performance: return .performance
        case .balanced: return .balanced
        case .quality: return .quality
        }
    }

    /// "1344 × 1408"
    public var dimensions: String {
        "\(perEyeResolution.width) × \(perEyeResolution.height)"
    }

    /// "Quality · 1344 × 1408"
    public var label: String {
        "\(rawValue.prefix(1).uppercased())\(rawValue.dropFirst()) · \(dimensions)"
    }
}

public enum StreamConnectionMode: String, Codable, CaseIterable, Sendable {
    case wired
    case wifi

    public var label: String { self == .wired ? "USB cable" : "Wireless (Wi-Fi)" }
}

public struct StreamLaunchSettings: Codable, Equatable, Sendable {
    public var connection = StreamConnectionMode.wired
    public var fps = 72
    public var megabits = 30
    public var resolution = ResolutionSelection.quality
    public var latency = StreamLatencyPreset.low
    public var audioDeviceName: String?

    public init() {}

    public var arguments: [String] {
        var values = [
            connection == .wired ? "--wired" : "--wireless",
            "--fps", String(fps), "--mbps", String(megabits),
            "--resolution", resolution.rawValue, "--latency", latency.rawValue,
        ]
        if let audioDeviceName, !audioDeviceName.isEmpty {
            values += ["--audio-device", audioDeviceName, "--route-audio"]
        }
        return values
    }
}

public struct StreamMetricSample: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let date: Date
    public let fps: Double?
    public let megabits: Double?
    public let latencyMilliseconds: Double?

    public init(date: Date = Date(), fps: Double? = nil,
                megabits: Double? = nil, latencyMilliseconds: Double? = nil) {
        self.date = date
        self.fps = fps
        self.megabits = megabits
        self.latencyMilliseconds = latencyMilliseconds
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.date == rhs.date && lhs.fps == rhs.fps
            && lhs.megabits == rhs.megabits
            && lhs.latencyMilliseconds == rhs.latencyMilliseconds
    }
}

public enum StreamLogMetricsParser {
    /// A dashboard sample from one streamer report line (`StreamReport`).
    public static func parse(line: String, date: Date = Date()) -> StreamMetricSample? {
        guard let values = StreamReport.parse(line) else { return nil }
        return StreamMetricSample(
            date: date, fps: values.questFPS, megabits: values.videoMegabits,
            latencyMilliseconds: values.latencyMilliseconds)
    }
}

/// Recognizes the streamer's report that it refused the game's OpenXR runtime
/// (typically a stale bottle DLL speaking another control protocol). The game
/// keeps running headless, so the manager must say why the headset is black.
public enum RuntimeConnectionRefusal {
    public static func message(in line: some StringProtocol) -> String? {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(RuntimeLink.connectionRefusedLogPrefix) else { return nil }
        let reason = value.dropFirst(RuntimeLink.connectionRefusedLogPrefix.count)
        return reason.isEmpty ? nil : "The game's OpenXR runtime was refused: \(reason)"
    }
}

public enum StreamerLogFailure {
    public static func message(in log: String) -> String? {
        log.split(whereSeparator: \.isNewline).reversed().compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.lowercased().hasPrefix("error:") else { return nil }
            let message = value.dropFirst("error:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? nil : message
        }.first
    }
}
