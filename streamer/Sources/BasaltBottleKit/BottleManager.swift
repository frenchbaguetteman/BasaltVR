import Foundation

public struct BottleToolError: LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum BottleEngineKind: String, Codable, CaseIterable, Sendable {
    case pinned
    case whisky
    case gptk
}

public struct BottleEngine: Equatable, Sendable {
    public let id: String
    public let kind: BottleEngineKind
    public let wineBinary: URL
    public let wineserverBinary: URL
    public let root: URL
    public let supportsBasaltDXMT: Bool

    public init(id: String, kind: BottleEngineKind, wineBinary: URL,
                wineserverBinary: URL, root: URL,
                supportsBasaltDXMT: Bool) {
        self.id = id
        self.kind = kind
        self.wineBinary = wineBinary
        self.wineserverBinary = wineserverBinary
        self.root = root
        self.supportsBasaltDXMT = supportsBasaltDXMT
    }
}

public struct ManagedBottle: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var name: String
    public var engineKind: BottleEngineKind
    public var engineID: String
    public var prefixPath: String
    public var engineRootPath: String
    public var wineBinaryPath: String
    public var createdAt: Date
    public var dxmtInstalled: Bool
    public var runtimeInstalled: Bool

    public init(name: String, engine: BottleEngine, prefix: URL,
                engineRoot: URL, wineBinary: URL, createdAt: Date = Date()) {
        formatVersion = Self.currentFormatVersion
        self.name = name
        engineKind = engine.kind
        engineID = engine.id
        prefixPath = prefix.path
        engineRootPath = engineRoot.path
        wineBinaryPath = wineBinary.path
        self.createdAt = createdAt
        dxmtInstalled = false
        runtimeInstalled = false
    }

    /// Both the DXMT handoff and the OpenXR runtime are installed.
    public var isReadyForVR: Bool { dxmtInstalled && runtimeInstalled }
}

public enum LaunchSource: String, Codable, CaseIterable, Sendable {
    case direct
    case steam
    case bsmanager
    case itch
}

public struct LaunchProfile: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var name: String
    public var bottleName: String
    public var source: LaunchSource
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(name: String, bottleName: String, source: LaunchSource,
                executable: String, arguments: [String] = [],
                workingDirectory: String? = nil,
                environment: [String: String] = [:]) {
        formatVersion = Self.currentFormatVersion
        self.name = name
        self.bottleName = bottleName
        self.source = source
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public struct CommandOutput: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }

    /// The combined output without surrounding whitespace, for error messages.
    public var trimmedOutput: String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A fully resolved, validated process invocation for a launch profile.
/// Native front ends use this to own the child process lifecycle while the
/// CLI continues to use the synchronous command runner below.
public struct BottleLaunchCommand: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectory: URL?

    public init(executable: URL, arguments: [String],
                environment: [String: String], currentDirectory: URL?) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

public protocol BottleCommandRunning: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?) throws -> CommandOutput
}

public struct ProcessBottleCommandRunner: BottleCommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String],
                    environment: [String: String], currentDirectory: URL?) throws
        -> CommandOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment { mergedEnvironment[key] = value }
        process.environment = mergedEnvironment
        process.currentDirectoryURL = currentDirectory
        // Wine intentionally leaves wineserver and Windows service processes
        // alive after commands such as wineboot exit. Those descendants inherit
        // stdout/stderr, so reading a Pipe to EOF can block forever even though
        // the Process we launched has already terminated. A temporary regular
        // file lets us wait only for the direct child and then read its output.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BasaltVR-command-\(UUID().uuidString).log")
        guard FileManager.default.createFile(
            atPath: outputURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw BottleToolError("Could not create temporary command output")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
        } catch {
            throw BottleToolError("Could not open temporary command output: \(error.localizedDescription)")
        }
        defer { try? outputHandle.close() }
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        do {
            try process.run()
        } catch {
            throw BottleToolError("Could not run \(executable.path): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        try? outputHandle.synchronize()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return CommandOutput(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self))
    }
}

public enum BottleName {
    public static func validate(_ value: String, kind: String = "name") throws -> String {
        guard !value.isEmpty, value.count <= 64,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                          options: .regularExpression) != nil else {
            throw BottleToolError(
                "Invalid \(kind) '\(value)'; use 1-64 ASCII letters, digits, '.', '_', or '-', starting with a letter or digit")
        }
        return value
    }
}

public struct BasaltManagedPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var bottles: URL { root.appendingPathComponent("Bottles", isDirectory: true) }
    public var profiles: URL { root.appendingPathComponent("Profiles", isDirectory: true) }

    public func bottleDirectory(_ name: String) throws -> URL {
        let safeName = try BottleName.validate(name, kind: "bottle name")
        return bottles.appendingPathComponent(safeName, isDirectory: true)
    }

    public func bottleMetadata(_ name: String) throws -> URL {
        try bottleDirectory(name).appendingPathComponent("bottle.json")
    }

    public func profileFile(_ name: String) throws -> URL {
        let safeName = try BottleName.validate(name, kind: "profile name")
        return profiles.appendingPathComponent(safeName).appendingPathExtension("json")
    }

    public func contains(_ url: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(rootPath + "/")
    }
}

public enum BottleEngineDiscovery {
    public static let pinnedDXMTEngineID = "pinned-wine-11.10-dxmt-0.80"

    public static func discover(repoRoot: URL,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                fileManager: FileManager = .default) -> [BottleEngine] {
        var engines = [BottleEngine]()

        let pinnedRoot = repoRoot.appendingPathComponent(
            "runtime/build/dxmt/toolchain/wine-11.10/Wine Devel.app/Contents/Resources/wine",
            isDirectory: true)
        let pinnedWine = pinnedRoot.appendingPathComponent("bin/wine")
        let pinnedServer = pinnedRoot.appendingPathComponent("bin/wineserver")
        // The Basalt winemetal fork supplies a Cocoa fallback when this Wine
        // driver hides DXMT's optional Metal-view bridge exports. Requiring the
        // driver itself here also keeps incomplete Wine bundles out.
        let pinnedMacDriver = pinnedRoot.appendingPathComponent(
            "lib/wine/x86_64-unix/winemac.so")
        let fork = repoRoot.appendingPathComponent(
            "runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so")
        if fileManager.isExecutableFile(atPath: pinnedWine.path),
           fileManager.isExecutableFile(atPath: pinnedServer.path),
           fileManager.fileExists(atPath: pinnedMacDriver.path),
           fileManager.fileExists(atPath: fork.path) {
            engines.append(BottleEngine(
                id: pinnedDXMTEngineID, kind: .pinned,
                wineBinary: pinnedWine, wineserverBinary: pinnedServer,
                root: pinnedRoot, supportsBasaltDXMT: true))
        }

        let whiskyRoot = home.appendingPathComponent(
            "Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine",
            isDirectory: true)
        let whiskyWine = whiskyRoot.appendingPathComponent("bin/wine64")
        let whiskyServer = whiskyRoot.appendingPathComponent("bin/wineserver")
        if fileManager.isExecutableFile(atPath: whiskyWine.path),
           fileManager.isExecutableFile(atPath: whiskyServer.path) {
            engines.append(BottleEngine(
                id: "whisky-shared", kind: .whisky,
                wineBinary: whiskyWine, wineserverBinary: whiskyServer,
                root: whiskyRoot, supportsBasaltDXMT: false))
        }

        let gptkRoots = [
            URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app/Contents/Resources/wine"),
            URL(fileURLWithPath: "/Applications/Game Porting Toolkit 2.app/Contents/Resources/wine"),
            URL(fileURLWithPath: "/usr/local/apple/apple_gptk"),
        ]
        for (index, root) in gptkRoots.enumerated() {
            let wine64 = root.appendingPathComponent("bin/wine64")
            let wine = fileManager.isExecutableFile(atPath: wine64.path)
                ? wine64 : root.appendingPathComponent("bin/wine")
            let server = root.appendingPathComponent("bin/wineserver")
            if fileManager.isExecutableFile(atPath: wine.path),
               fileManager.isExecutableFile(atPath: server.path) {
                engines.append(BottleEngine(
                    id: "gptk-\(index + 1)", kind: .gptk,
                    wineBinary: wine, wineserverBinary: server,
                    root: root, supportsBasaltDXMT: false))
            }
        }
        return engines
    }
}

public final class BottleManager: @unchecked Sendable {
    public let paths: BasaltManagedPaths
    public let repoRoot: URL
    private let fileManager: FileManager
    private let runner: any BottleCommandRunning
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL, repoRoot: URL,
                fileManager: FileManager = .default,
                runner: any BottleCommandRunning = ProcessBottleCommandRunner()) {
        paths = BasaltManagedPaths(root: root)
        self.repoRoot = repoRoot.standardizedFileURL
        self.fileManager = fileManager
        self.runner = runner
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = ProcessInfo.processInfo.environment["BASALT_DATA_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(
            "Library/Application Support/BasaltVR", isDirectory: true)
    }

    public func prepare() throws {
        try fileManager.createDirectory(at: paths.root,
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.bottles,
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.profiles,
                                        withIntermediateDirectories: true)
        let resolvedRoot = paths.root.resolvingSymlinksInPath()
        for directory in [paths.bottles, paths.profiles] {
            let resolved = directory.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(resolvedRoot.path + "/") else {
                throw BottleToolError(
                    "Managed directory resolves outside the Basalt data root: \(directory.path)")
            }
        }
    }

    public func engines() -> [BottleEngine] {
        BottleEngineDiscovery.discover(repoRoot: repoRoot, fileManager: fileManager)
    }

    public func listBottles() throws -> [ManagedBottle] {
        guard fileManager.fileExists(atPath: paths.bottles.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: paths.bottles, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .compactMap { directory in
                let metadata = directory.appendingPathComponent("bottle.json")
                guard let data = try? Data(contentsOf: metadata) else { return nil }
                return try? decoder.decode(ManagedBottle.self, from: data)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func loadBottle(_ name: String) throws -> ManagedBottle {
        let metadata = try paths.bottleMetadata(name)
        guard let data = try? Data(contentsOf: metadata) else {
            throw BottleToolError("Managed bottle '\(name)' does not exist")
        }
        let bottle = try decoder.decode(ManagedBottle.self, from: data)
        guard bottle.formatVersion == ManagedBottle.currentFormatVersion else {
            throw BottleToolError("Bottle '\(name)' uses unsupported metadata version \(bottle.formatVersion)")
        }
        let directory = try paths.bottleDirectory(name).standardizedFileURL
        let expectedPrefix = directory.appendingPathComponent(
            "prefix", isDirectory: true).standardizedFileURL
        let prefix = URL(fileURLWithPath: bottle.prefixPath).standardizedFileURL
        let engineRoot = URL(fileURLWithPath: bottle.engineRootPath).standardizedFileURL
        let wine = URL(fileURLWithPath: bottle.wineBinaryPath).standardizedFileURL
        guard bottle.name == name, prefix == expectedPrefix else {
            throw BottleToolError("Bottle '\(name)' metadata does not match its managed directory")
        }
        let resolvedRoot = paths.root.resolvingSymlinksInPath()
        guard prefix.resolvingSymlinksInPath().path.hasPrefix(
                resolvedRoot.path + "/") else {
            throw BottleToolError("Bottle '\(name)' prefix resolves outside the managed root")
        }
        guard wine.path.hasPrefix(engineRoot.path + "/") else {
            throw BottleToolError("Bottle '\(name)' Wine executable is outside its engine")
        }
        if bottle.engineKind == .pinned {
            let expectedEngine = directory.appendingPathComponent(
                "engine", isDirectory: true).standardizedFileURL
            guard engineRoot == expectedEngine,
                  wine == expectedEngine.appendingPathComponent("bin/wine") else {
                throw BottleToolError(
                    "Bottle '\(name)' pinned engine escapes its managed directory")
            }
        } else {
            guard let discovered = engines().first(where: {
                $0.id == bottle.engineID && $0.kind == bottle.engineKind
            }), discovered.root.standardizedFileURL == engineRoot,
               discovered.wineBinary.standardizedFileURL == wine else {
                throw BottleToolError(
                    "Bottle '\(name)' shared \(bottle.engineKind.rawValue) engine is no longer available")
            }
        }
        return bottle
    }

    public func createBottle(name: String, engineID: String) throws -> ManagedBottle {
        try createBottle(name: name, engineID: engineID, initializePrefix: true)
    }

    private func createBottle(name: String, engineID: String,
                              initializePrefix: Bool) throws -> ManagedBottle {
        try prepare()
        let directory = try paths.bottleDirectory(name)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw BottleToolError("Managed bottle '\(name)' already exists")
        }
        guard let engine = engines().first(where: { $0.id == engineID }) else {
            throw BottleToolError("Wine engine '\(engineID)' is not available")
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        // A half-made bottle keeps its name taken and has no delete action, so
        // every failure after this point removes the directory again.
        var created = false
        defer { if !created { try? fileManager.removeItem(at: directory) } }
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let selectedEngineRoot: URL
        let selectedWine: URL
        if engine.kind == .pinned {
            let isolated = directory.appendingPathComponent("engine", isDirectory: true)
            let clone = try runner.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-cR", engine.root.path, isolated.path],
                environment: [:], currentDirectory: nil)
            guard clone.status == 0 else {
                throw BottleToolError("Could not clone the pinned Wine engine: \(clone.trimmedOutput)")
            }
            selectedEngineRoot = isolated
            selectedWine = isolated.appendingPathComponent("bin/wine")
        } else {
            selectedEngineRoot = engine.root
            selectedWine = engine.wineBinary
        }

        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
        var bottle = ManagedBottle(
            name: name, engine: engine, prefix: prefix,
            engineRoot: selectedEngineRoot, wineBinary: selectedWine)
        try saveBottle(bottle)

        guard initializePrefix else {
            created = true
            return bottle
        }

        let bootBinary = selectedEngineRoot.appendingPathComponent("bin/wineboot")
        let boot: CommandOutput
        if fileManager.isExecutableFile(atPath: bootBinary.path) {
            boot = try bottleCommand(
                bottle: bottle, executable: bootBinary, arguments: ["-u"],
                extraEnvironment: [:])
        } else {
            boot = try wineCommand(
                bottle: bottle, arguments: ["wineboot", "-u"],
                extraEnvironment: [:])
        }
        guard boot.status == 0 else {
            throw BottleToolError("wineboot failed for '\(name)': \(boot.trimmedOutput)")
        }
        bottle = try loadBottle(name)
        created = true
        return bottle
    }

    /// Creates an isolated Basalt bottle, then APFS-clones an existing Wine
    /// prefix into it. The source is never patched or modified. This is the
    /// supported bridge from Whisky/CrossOver into the Basalt VR runtime.
    public func importPrefix(name: String, engineID: String,
                             sourcePrefix: URL) throws -> ManagedBottle {
        let source = sourcePrefix.standardizedFileURL
        guard fileManager.fileExists(atPath: source.appendingPathComponent("drive_c").path),
              fileManager.fileExists(atPath: source.appendingPathComponent("system.reg").path) else {
            throw BottleToolError("Import source is not a complete Wine prefix: \(source.path)")
        }
        guard !paths.contains(source) else {
            throw BottleToolError("A managed Basalt prefix cannot be imported as an external bottle")
        }
        // Do not boot an imported prefix here. wineboot processes Windows Run
        // entries, which can launch Steam's updater and turn a file copy into an
        // unexpected interactive/network operation. The first intentional Wine
        // launch will update the cloned prefix with the selected engine.
        let bottle = try createBottle(
            name: name, engineID: engineID, initializePrefix: false)
        do {
            let destination = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            let copy = try runner.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-cR", source.path + "/.", destination.path],
                environment: [:], currentDirectory: nil)
            guard copy.status == 0 else {
                throw BottleToolError(
                    "Could not copy the external prefix: "
                        + copy.trimmedOutput)
            }
            try suppressSteamAutoLaunch(in: destination)
            return try loadBottle(name)
        } catch {
            try? fileManager.removeItem(at: paths.bottleDirectory(name))
            throw error
        }
    }

    /// Prevent Wine maintenance commands from processing Steam's login Run
    /// entry. This only changes the isolated managed clone; launching Steam or
    /// a Steam profile explicitly continues to work normally.
    private func suppressSteamAutoLaunch(in prefix: URL) throws {
        let registry = prefix.appendingPathComponent("user.reg")
        guard fileManager.fileExists(atPath: registry.path) else { return }
        var lines = try String(contentsOf: registry, encoding: .utf8)
            .components(separatedBy: "\n")
        var section = ""
        var changed = false
        lines = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = trimmed.lowercased()
                return line
            }
            if section == #"[software\\microsoft\\windows\\currentversion\\run]"#,
               trimmed.lowercased().hasPrefix(#""steam"="#) {
                changed = true
                return nil
            }
            if section == #"[software\\valve\\steam]"#,
               trimmed.lowercased().hasPrefix(#""suppressautorun"="#),
               trimmed.lowercased() != #""suppressautorun"=dword:00000001"# {
                changed = true
                return #""SuppressAutoRun"=dword:00000001"#
            }
            return line
        }
        if changed {
            try lines.joined(separator: "\n").write(
                to: registry, atomically: true, encoding: .utf8)
        }
    }

    public func installDXMT(in name: String) throws -> ManagedBottle {
        var bottle = try loadBottle(name)
        guard bottle.engineKind == .pinned else {
            throw BottleToolError(
                "Basalt DXMT requires an isolated pinned engine; shared \(bottle.engineKind.rawValue) engines are never patched")
        }
        guard let compatibleEngine = engines().first(where: {
            $0.kind == .pinned && $0.supportsBasaltDXMT
        }) else {
            throw BottleToolError(
                "The pinned Wine/DXMT engine is unavailable; build the Basalt DXMT fork first")
        }
        if bottle.engineID != compatibleEngine.id {
            bottle = try replacePinnedEngine(in: bottle, with: compatibleEngine)
        }
        let fork = repoRoot.appendingPathComponent("runtime/build/dxmt/fork-install")
        let windows = fork.appendingPathComponent("x86_64-windows")
        let unix = fork.appendingPathComponent("x86_64-unix/winemetal.so")
        let engineRoot = URL(fileURLWithPath: bottle.engineRootPath)
        let engineWindows = engineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        let engineUnix = engineRoot.appendingPathComponent("lib/wine/x86_64-unix/winemetal.so")
        let system32 = URL(fileURLWithPath: bottle.prefixPath)
            .appendingPathComponent("drive_c/windows/system32")
        try fileManager.createDirectory(at: engineWindows, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: system32, withIntermediateDirectories: true)
        for dll in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"] {
            let source = windows.appendingPathComponent(dll)
            guard fileManager.fileExists(atPath: source.path) else {
                throw BottleToolError("Missing Basalt DXMT artifact: \(source.path)")
            }
            try copyFile(source, to: engineWindows.appendingPathComponent(dll))
            try copyFile(source, to: system32.appendingPathComponent(dll))
        }
        guard fileManager.fileExists(atPath: unix.path) else {
            throw BottleToolError("Missing Basalt DXMT artifact: \(unix.path)")
        }
        try copyFile(unix, to: engineUnix)
        bottle.dxmtInstalled = true
        try saveBottle(bottle)
        return bottle
    }

    /// Replaces only the bottle's isolated Wine program files. The prefix,
    /// installed games, Steam data, and profiles remain untouched. This moves
    /// legacy bottles onto the pinned Wine engine used by Basalt's tested
    /// D3DKMT shared-resource path.
    private func replacePinnedEngine(in existing: ManagedBottle,
                                     with provider: BottleEngine) throws -> ManagedBottle {
        var bottle = existing
        let engineRoot = URL(fileURLWithPath: bottle.engineRootPath, isDirectory: true)
            .standardizedFileURL
        let bottleDirectory = try paths.bottleDirectory(bottle.name).standardizedFileURL
        let expectedEngine = bottleDirectory.appendingPathComponent(
            "engine", isDirectory: true).standardizedFileURL
        guard engineRoot == expectedEngine else {
            throw BottleToolError("Refusing to replace a pinned engine outside its bottle")
        }

        let token = UUID().uuidString
        let replacement = bottleDirectory.appendingPathComponent(
            "engine-upgrade-\(token)", isDirectory: true)
        let backup = bottleDirectory.appendingPathComponent(
            "engine-backup-\(token)", isDirectory: true)
        let clone = try runner.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-cR", provider.root.path, replacement.path],
            environment: [:], currentDirectory: nil)
        guard clone.status == 0,
              fileManager.isExecutableFile(atPath: replacement.appendingPathComponent("bin/wine").path),
              fileManager.fileExists(atPath: replacement.appendingPathComponent(
                "lib/wine/x86_64-unix/winemac.so").path) else {
            try? fileManager.removeItem(at: replacement)
            throw BottleToolError(
                "Could not clone the DXMT-matched Wine engine: "
                    + clone.trimmedOutput)
        }

        do {
            try fileManager.moveItem(at: engineRoot, to: backup)
            try fileManager.moveItem(at: replacement, to: engineRoot)
            bottle.engineID = provider.id
            bottle.wineBinaryPath = engineRoot.appendingPathComponent("bin/wine").path
            bottle.dxmtInstalled = false
            try saveBottle(bottle)
            try? fileManager.removeItem(at: backup)
            return bottle
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                if fileManager.fileExists(atPath: engineRoot.path) {
                    try? fileManager.moveItem(at: engineRoot, to: replacement)
                }
                try? fileManager.moveItem(at: backup, to: engineRoot)
            }
            try? fileManager.removeItem(at: replacement)
            throw error
        }
    }

    public func installRuntime(in name: String) throws -> ManagedBottle {
        try installRuntime(in: name, alwaysRegister: true)
    }

    /// Brings a stopped bottle's runtime in line with this build before a
    /// launch. Unchanged files are left alone, and Wine runs to register the
    /// runtime only when the bottle's registry hive does not already name it:
    /// starting Wine cold-boots the prefix, which a launch otherwise pays for
    /// on every Play. Call it only while the bottle's wineserver is stopped,
    /// since a running server may not have flushed `system.reg` yet.
    @discardableResult
    public func syncRuntime(in name: String) throws -> ManagedBottle {
        try installRuntime(in: name, alwaysRegister: false)
    }

    static let runtimeManifestWindowsPath = #"C:\basalt\runtime\basalt_openxr.json"#

    /// The OpenXR `ActiveRuntime` recorded in a prefix's `system.reg`, read
    /// without starting Wine; nil when the key or value is absent.
    static func activeOpenXRRuntime(inHive hive: Data) -> String? {
        // Hives are ASCII (Wine escapes everything else), relative to HKLM,
        // and double each backslash. Keys are case-insensitive, so search a
        // lowercased copy: a byte search stays fast on multi-megabyte hives.
        let lowercased = Data(hive.map { (65...90).contains($0) ? $0 + 32 : $0 })
        let header = Data("\n[software\\\\khronos\\\\openxr\\\\1]".utf8)
        guard let section = lowercased.range(of: header) else { return nil }
        let end = lowercased.range(
            of: Data("\n[".utf8), in: section.upperBound..<lowercased.endIndex)?
            .lowerBound ?? lowercased.endIndex
        let body = String(decoding: hive[section.upperBound..<end], as: UTF8.self)
        let name = #""activeruntime"=""#
        for line in body.split(separator: "\n")
        where line.count > name.count + 1 && line.hasSuffix("\"")
            && line.prefix(name.count).lowercased() == name {
            var value = ""
            var escaped = false
            for character in line.dropFirst(name.count).dropLast() {
                if escaped || character != "\\" {
                    value.append(character)
                    escaped = false
                } else {
                    escaped = true
                }
            }
            return value
        }
        return nil
    }

    private func hiveNamesBasaltRuntime(_ bottle: ManagedBottle) -> Bool {
        let hive = URL(fileURLWithPath: bottle.prefixPath).appendingPathComponent("system.reg")
        guard let data = try? Data(contentsOf: hive),
              let active = Self.activeOpenXRRuntime(inHive: data) else { return false }
        return active.caseInsensitiveCompare(Self.runtimeManifestWindowsPath) == .orderedSame
    }

    private func installRuntime(in name: String, alwaysRegister: Bool) throws -> ManagedBottle {
        var bottle = try loadBottle(name)
        let buildBin = repoRoot.appendingPathComponent("runtime/build/bin")
        let sourceDLL = buildBin.appendingPathComponent("basalt_openxr.dll")
        let sourceManifest = buildBin.appendingPathComponent("basalt_openxr.json")
        guard fileManager.fileExists(atPath: sourceDLL.path),
              fileManager.fileExists(atPath: sourceManifest.path) else {
            throw BottleToolError(
                "The OpenXR runtime is not built; run runtime/scripts/test-dxmt.zsh first")
        }
        let destination = URL(fileURLWithPath: bottle.prefixPath)
            .appendingPathComponent("drive_c/basalt/runtime", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try copyFile(sourceDLL, to: destination.appendingPathComponent("basalt_openxr.dll"))
        try copyFile(sourceManifest, to: destination.appendingPathComponent("basalt_openxr.json"))

        if alwaysRegister || !bottle.runtimeInstalled || !hiveNamesBasaltRuntime(bottle) {
            let registry = try wineCommand(
                bottle: bottle,
                arguments: [
                    "reg.exe", "add", #"HKLM\Software\Khronos\OpenXR\1"#,
                    "/v", "ActiveRuntime", "/t", "REG_SZ", "/d",
                    Self.runtimeManifestWindowsPath, "/f",
                ],
                extraEnvironment: [:])
            guard registry.status == 0 else {
                throw BottleToolError("OpenXR registration failed: \(registry.trimmedOutput)")
            }
        }
        if !bottle.runtimeInstalled {
            bottle.runtimeInstalled = true
            try saveBottle(bottle)
        }
        return bottle
    }

    public func verify(_ name: String) throws -> String {
        let bottle = try loadBottle(name)
        guard bottle.dxmtInstalled, bottle.runtimeInstalled else {
            throw BottleToolError(
                "Bottle '\(name)' is incomplete (DXMT=\(bottle.dxmtInstalled), runtime=\(bottle.runtimeInstalled))")
        }
        let prefix = URL(fileURLWithPath: bottle.prefixPath)
        let expected = [
            prefix.appendingPathComponent("drive_c/basalt/runtime/basalt_openxr.dll"),
            prefix.appendingPathComponent("drive_c/basalt/runtime/basalt_openxr.json"),
            prefix.appendingPathComponent("drive_c/windows/system32/d3d11.dll"),
            URL(fileURLWithPath: bottle.engineRootPath)
                .appendingPathComponent("lib/wine/x86_64-unix/winemetal.so"),
        ]
        for path in expected where !fileManager.fileExists(atPath: path.path) {
            throw BottleToolError("Bottle verification is missing \(path.path)")
        }
        let query = try wineCommand(
            bottle: bottle,
            arguments: [
                "reg.exe", "query", #"HKLM\Software\Khronos\OpenXR\1"#,
                "/v", "ActiveRuntime",
            ], extraEnvironment: [:])
        guard query.status == 0,
              query.output.lowercased().contains(#"c:\basalt\runtime\basalt_openxr.json"#) else {
            throw BottleToolError("Bottle verification could not confirm ActiveRuntime: \(query.trimmedOutput)")
        }
        let loaderSmoke = repoRoot.appendingPathComponent(
            "runtime/build/bin/loader_smoke.exe")
        guard fileManager.fileExists(atPath: loaderSmoke.path) else {
            throw BottleToolError("Bottle verification is missing \(loaderSmoke.path)")
        }
        let smoke = try wineCommand(
            bottle: bottle, arguments: [loaderSmoke.path],
            extraEnvironment: [
                "BASALT_EXPECT_D3D11_EXTENSION": "1",
                "DXMT_BASALT_IOSURFACE": "1",
                "MVK_CONFIG_LOG_LEVEL": "0",
            ],
            currentDirectory: loaderSmoke.deletingLastPathComponent())
        guard smoke.status == 0 else {
            throw BottleToolError(
                "OpenXR loader smoke failed in '\(name)': \(smoke.trimmedOutput)")
        }
        return "PASS: \(name) has an isolated Basalt DXMT engine, registered OpenXR runtime, and working loader"
    }

    public func saveProfile(_ profile: LaunchProfile) throws {
        try prepare()
        _ = try BottleName.validate(profile.name, kind: "profile name")
        _ = try loadBottle(profile.bottleName)
        guard !profile.executable.isEmpty else {
            throw BottleToolError("Profile executable cannot be empty")
        }
        let data = try encoder.encode(profile)
        try data.write(to: paths.profileFile(profile.name), options: .atomic)
    }

    public func loadProfile(_ name: String) throws -> LaunchProfile {
        let file = try paths.profileFile(name)
        guard let data = try? Data(contentsOf: file) else {
            throw BottleToolError("Launch profile '\(name)' does not exist")
        }
        let profile = try decoder.decode(LaunchProfile.self, from: data)
        guard profile.formatVersion == LaunchProfile.currentFormatVersion else {
            throw BottleToolError("Profile '\(name)' uses unsupported metadata version \(profile.formatVersion)")
        }
        return profile
    }

    public func listProfiles() throws -> [LaunchProfile] {
        guard fileManager.fileExists(atPath: paths.profiles.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: paths.profiles, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? decoder.decode(LaunchProfile.self, from: data)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func deleteProfile(_ name: String) throws {
        let file = try paths.profileFile(name)
        guard paths.contains(file) else {
            throw BottleToolError("Refusing to delete a profile outside the managed root")
        }
        guard fileManager.fileExists(atPath: file.path) else {
            throw BottleToolError("Launch profile '\(name)' does not exist")
        }
        try fileManager.removeItem(at: file)
    }

    public func installOpenComposite(profileName: String, artifact: URL,
                                     targetDLL: URL) throws -> URL {
        let profile = try loadProfile(profileName)
        let bottle = try loadBottle(profile.bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath).standardizedFileURL
        let target = targetDLL.standardizedFileURL
        guard target.path.hasPrefix(prefix.path + "/") else {
            throw BottleToolError("OpenComposite target must be inside the managed bottle prefix")
        }
        let resolvedPrefix = prefix.resolvingSymlinksInPath()
        var existingAncestor = target.deletingLastPathComponent()
        while !fileManager.fileExists(atPath: existingAncestor.path),
              existingAncestor.path != "/" {
            existingAncestor.deleteLastPathComponent()
        }
        let resolvedAncestor = existingAncestor.resolvingSymlinksInPath()
        guard resolvedAncestor == resolvedPrefix ||
                resolvedAncestor.path.hasPrefix(resolvedPrefix.path + "/") else {
            throw BottleToolError(
                "OpenComposite target resolves outside the managed bottle prefix")
        }
        guard target.lastPathComponent.lowercased() == "openvr_api.dll" else {
            throw BottleToolError("OpenComposite target must be named openvr_api.dll")
        }
        let bytes = try Data(contentsOf: artifact)
        guard bytes.count >= 2, bytes[bytes.startIndex] == 0x4d,
              bytes[bytes.index(after: bytes.startIndex)] == 0x5a else {
            throw BottleToolError("OpenComposite artifact is not a Windows PE DLL")
        }
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let resolvedParent = target.deletingLastPathComponent().resolvingSymlinksInPath()
        guard resolvedParent == resolvedPrefix ||
                resolvedParent.path.hasPrefix(resolvedPrefix.path + "/") else {
            throw BottleToolError(
                "OpenComposite target resolves outside the managed bottle prefix")
        }
        if fileManager.fileExists(atPath: target.path) {
            let backup = target.appendingPathExtension("basalt-original")
            if !fileManager.fileExists(atPath: backup.path) {
                try copyFile(target, to: backup)
            }
        }
        try bytes.write(to: target, options: .atomic)
        let configuration = """
        ; Managed by BasaltVR. OpenComposite remains a separately supplied GPLv3 artifact.
        initUsingVulkan=false
        enableAudio=false
        """
        try configuration.write(
            to: target.deletingLastPathComponent()
                .appendingPathComponent("opencomposite.ini"),
            atomically: true, encoding: .utf8)
        return target
    }

    public func runProfile(_ name: String, controlFile: URL,
                           additionalArguments: [String] = []) throws -> CommandOutput {
        let command = try profileLaunchCommand(
            name, controlFile: controlFile,
            additionalArguments: additionalArguments)
        return try runner.run(
            executable: command.executable,
            arguments: command.arguments,
            environment: command.environment,
            currentDirectory: command.currentDirectory)
    }

    public func profileLaunchCommand(
        _ name: String, controlFile: URL,
        additionalArguments: [String] = []
    ) throws -> BottleLaunchCommand {
        let profile = try loadProfile(name)
        let bottle = try loadBottle(profile.bottleName)
        guard bottle.dxmtInstalled, bottle.runtimeInstalled else {
            throw BottleToolError("Bottle '\(bottle.name)' must install DXMT and the runtime before launch")
        }
        guard fileManager.fileExists(atPath: controlFile.path) else {
            throw BottleToolError(
                "Runtime control file does not exist; start basalt-streamer --wired --runtime <path> first")
        }
        var environment = profile.environment
        var windowsExecutable = profile.executable
        var profileArguments = profile.arguments
        var workingDirectory = profile.workingDirectory.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }

        // A `steam.exe -applaunch` invocation is only a message to the already
        // running Steam client. Wine returns as soon as Steam accepts it, and
        // the eventual game inherits Steam's old environment instead of this
        // session's BASALT_CONTROL path. Resolve the initial Beat Saber target
        // to the actual executable so Basalt owns the real game lifetime and
        // supplies the current OpenXR session environment.
        if profile.source == .steam,
           let appLaunchIndex = profileArguments.firstIndex(of: "-applaunch"),
           profileArguments.indices.contains(appLaunchIndex + 1),
           profileArguments[appLaunchIndex + 1] == "620980" {
            let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            let candidates = [
                prefix.appendingPathComponent(
                    "drive_c/Program Files (x86)/Steam/steamapps/common/Beat Saber/Beat Saber.exe"),
                prefix.appendingPathComponent(
                    "drive_c/Program Files/Steam/steamapps/common/Beat Saber/Beat Saber.exe"),
            ]
            guard let beatSaber = candidates.first(where: {
                fileManager.fileExists(atPath: $0.path)
            }) else {
                throw BottleToolError(
                    "Steam reports Beat Saber, but its executable is missing from the managed bottle. Open Steam, finish any pending update, then try again.")
            }
            windowsExecutable = Self.winePath(for: beatSaber, prefix: prefix)
            profileArguments.removeSubrange(appLaunchIndex...(appLaunchIndex + 1))
            workingDirectory = beatSaber.deletingLastPathComponent()
            environment["SteamAppId"] = "620980"
            environment["SteamGameId"] = "620980"
        }
        environment["DXMT_BASALT_IOSURFACE"] = "1"
        environment["BASALT_CONTROL"] = Self.winePath(for: controlFile,
                                                       prefix: URL(fileURLWithPath: bottle.prefixPath))
        environment["WINEPREFIX"] = bottle.prefixPath
        environment["WINEARCH"] = "win64"
        environment["WINEDEBUG"] = environment["WINEDEBUG"] ?? "-all"
        environment["MVK_CONFIG_LOG_LEVEL"] = environment["MVK_CONFIG_LOG_LEVEL"] ?? "0"
        let executable = URL(fileURLWithPath: bottle.wineBinaryPath)
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw BottleToolError("Bottle executable is missing: \(executable.path)")
        }
        return BottleLaunchCommand(
            executable: executable,
            // Invoke the game directly. Steam's launcher is already running,
            // and start.exe can finish after a Steam game reparents itself,
            // which would make the manager tear down a still-running stream.
            arguments: [windowsExecutable] + profileArguments + additionalArguments,
            environment: environment,
            currentDirectory: workingDirectory)
    }

    /// Stops every Wine process owned by the managed bottle for `profileName`.
    ///
    /// A previous manager process can exit without getting a chance to run its
    /// termination handler. Resolving cleanup from persisted profile metadata
    /// lets the next session remove those orphaned Wine processes before it
    /// starts Steam or the game again.
    @discardableResult
    public func terminateBottleProcesses(
        forProfile profileName: String
    ) throws -> CommandOutput {
        try terminateBottleProcesses(launchedWith: prefixCommand(forProfile: profileName))
    }

    /// A command scoped to the managed bottle for `profileName`: it runs
    /// nothing itself, but `terminateBottleProcesses(launchedWith:)` can find
    /// that prefix's wineserver from it.
    public func prefixCommand(forProfile profileName: String) throws -> BottleLaunchCommand {
        let profile = try loadProfile(profileName)
        let bottle = try loadBottle(profile.bottleName)
        return BottleLaunchCommand(
            executable: URL(fileURLWithPath: bottle.wineBinaryPath),
            arguments: [],
            environment: [
                "WINEPREFIX": bottle.prefixPath,
                "WINEARCH": "win64",
                "WINEDEBUG": "-all",
            ],
            currentDirectory: nil)
    }

    /// Stops every Wine process owned by the prefix used for `command`.
    ///
    /// Terminating the direct `Process` returned by Foundation is not enough:
    /// Wine reparents long-lived Windows processes (including Steam, games,
    /// helpers, and services) to its per-prefix wineserver. Asking that server
    /// to shut down keeps cleanup scoped to this bottle instead of matching
    /// processes system-wide.
    @discardableResult
    public func terminateBottleProcesses(
        launchedWith command: BottleLaunchCommand
    ) throws -> CommandOutput {
        guard let prefixPath = command.environment["WINEPREFIX"],
              !prefixPath.isEmpty else {
            throw BottleToolError(
                "Cannot clean up Wine processes without a WINEPREFIX")
        }
        let wineserver = command.executable.deletingLastPathComponent()
            .appendingPathComponent("wineserver")
        guard fileManager.isExecutableFile(atPath: wineserver.path) else {
            throw BottleToolError(
                "Bottle wineserver is missing: \(wineserver.path)")
        }
        var environment = command.environment
        environment["WINEPREFIX"] = prefixPath
        environment["WINEDEBUG"] = environment["WINEDEBUG"] ?? "-all"
        let result = try runner.run(
            executable: wineserver,
            arguments: ["--kill", "--wait"],
            environment: environment,
            currentDirectory: nil)
        let detail = result.trimmedOutput
        if result.status == 0 {
            return result
        }
        // Wine returns status 1 with no diagnostic when --kill finds no
        // wineserver for the prefix. That is already the desired clean state,
        // not a launch-blocking failure. Preserve nonempty diagnostics and all
        // other statuses as real errors.
        if result.status == 1 && detail.isEmpty {
            return CommandOutput(status: 0, output: "")
        }
        throw BottleToolError(
            "Could not stop Wine processes for \(prefixPath)"
                + (detail.isEmpty ? "" : ": \(detail)"))
    }

    /// Resolves a normal Wine application without requiring an active VR
    /// stream. The management app uses this for Steam, installers, and bottle
    /// maintenance while still owning the resulting child process.
    public func applicationLaunchCommand(
        bottleName: String, executable windowsExecutable: String,
        arguments: [String] = [], environment extraEnvironment: [String: String] = [:],
        currentDirectory: URL? = nil
    ) throws -> BottleLaunchCommand {
        let bottle = try loadBottle(bottleName)
        let executable = URL(fileURLWithPath: bottle.wineBinaryPath)
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw BottleToolError("Bottle executable is missing: \(executable.path)")
        }
        var environment = extraEnvironment
        environment["WINEPREFIX"] = bottle.prefixPath
        environment["WINEARCH"] = "win64"
        environment["WINEDEBUG"] = environment["WINEDEBUG"] ?? "-all"
        environment["MVK_CONFIG_LOG_LEVEL"] = environment["MVK_CONFIG_LOG_LEVEL"] ?? "0"
        return BottleLaunchCommand(
            executable: executable,
            arguments: [windowsExecutable] + arguments,
            environment: environment,
            currentDirectory: currentDirectory)
    }

    /// Starts the Steam client before a waited, direct game executable. Steam's
    /// `-applaunch` command returns before the game exits, so Basalt launches
    /// Steam as a prerequisite and retains ownership of the actual game process.
    ///
    /// Steam's CEF helper cannot render its cross-process D3D surface through
    /// DXMT on macOS. Basalt's small launcher keeps GPU work in the main helper
    /// process and selects Chromium's software path, matching the working
    /// configuration used by CrossOver. The original helper remains beside it
    /// and is refreshed whenever Steam installs a newer copy.
    @discardableResult
    public func installSteamWebHelperCompatibility(
        forProfile name: String
    ) throws -> URL? {
        let profile = try loadProfile(name)
        guard profile.source == .steam || profile.source == .bsmanager else { return nil }
        let bottle = try loadBottle(profile.bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        let artifact = repoRoot.appendingPathComponent(
            "runtime/build/bin/steamwebhelper_compat.exe")
        guard fileManager.fileExists(atPath: artifact.path) else {
            throw BottleToolError(
                "Steam UI compatibility is not built; run runtime/scripts/test-dxmt.zsh first")
        }
        let shim = try Data(contentsOf: artifact)
        guard shim.count >= 2, shim[shim.startIndex] == 0x4d,
              shim[shim.index(after: shim.startIndex)] == 0x5a else {
            throw BottleToolError("Steam UI compatibility artifact is not a Windows PE executable")
        }
        guard Self.isSteamWebHelperShim(shim) else {
            throw BottleToolError("Steam UI compatibility artifact is not Basalt's helper launcher")
        }

        let candidates = [
            prefix.appendingPathComponent(
                "drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe"),
            prefix.appendingPathComponent(
                "drive_c/Program Files/Steam/bin/cef/cef.win64/steamwebhelper.exe"),
        ]
        guard let helper = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw BottleToolError(
                "Steam's web helper is missing in '\(bottle.name)'; let Steam finish updating, then try again")
        }
        let resolvedPrefix = prefix.resolvingSymlinksInPath()
        let resolvedHelper = helper.resolvingSymlinksInPath()
        guard resolvedHelper.path.hasPrefix(resolvedPrefix.path + "/") else {
            throw BottleToolError(
                "Steam's web helper resolves outside the managed bottle prefix")
        }
        let backup = helper.deletingPathExtension()
            .appendingPathExtension("basalt-original.exe")
        if fileManager.fileExists(atPath: backup.path) {
            let resolvedBackup = backup.resolvingSymlinksInPath()
            guard resolvedBackup.path.hasPrefix(resolvedPrefix.path + "/") else {
                throw BottleToolError(
                    "Steam's preserved web helper resolves outside the managed bottle prefix")
            }
        }
        let installed = try Data(contentsOf: helper)

        if !Self.isSteamWebHelperShim(installed) {
            guard installed.count >= 2, installed[installed.startIndex] == 0x4d,
                  installed[installed.index(after: installed.startIndex)] == 0x5a else {
                throw BottleToolError("Steam's web helper is not a Windows PE executable")
            }
            // This is either the initial install or a newer helper written by
            // Steam. Preserve that exact version for the shim to launch. Any
            // build of Basalt's own shim, including an older one, is skipped so
            // it can never replace the original and relaunch itself.
            try copyFile(helper, to: backup)
        } else {
            guard fileManager.fileExists(atPath: backup.path) else {
                throw BottleToolError(
                    "Steam UI compatibility is missing its preserved original helper")
            }
        }

        let original = try Data(contentsOf: backup)
        guard original.count >= 2, original[original.startIndex] == 0x4d,
              original[original.index(after: original.startIndex)] == 0x5a else {
            throw BottleToolError("Steam's preserved web helper is not a Windows PE executable")
        }
        guard !Self.isSteamWebHelperShim(original) else {
            throw BottleToolError(
                "Steam's preserved web helper was overwritten by the compatibility shim; verify Steam's files, then try again")
        }
        try copyFile(artifact, to: helper)
        return helper
    }

    /// Every build of the shim embeds the UTF-16 name of the helper it
    /// launches, which Steam's own helper never contains. Comparing bytes with
    /// the current artifact is not enough: rebuilds change the PE timestamp.
    static func isSteamWebHelperShim(_ executable: Data) -> Bool {
        let marker = Data("steamwebhelper.basalt-original.exe".utf16.flatMap {
            [UInt8($0 & 0xff), UInt8($0 >> 8)]
        })
        return executable.range(of: marker) != nil
    }

    public func steamBootstrapCommand(forProfile name: String) throws -> BottleLaunchCommand? {
        let profile = try loadProfile(name)
        guard profile.source == .steam || profile.source == .bsmanager else { return nil }
        let bottle = try loadBottle(profile.bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        let candidates = [
            prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"),
            prefix.appendingPathComponent("drive_c/Program Files/Steam/steam.exe"),
        ]
        guard let steam = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw BottleToolError("Steam is not installed in '\(bottle.name)'")
        }
        return try applicationLaunchCommand(
            bottleName: bottle.name,
            executable: Self.winePath(for: steam, prefix: prefix),
            // Keep the client visible: a copied or newly-created prefix may
            // need an interactive sign-in before SteamAPI exposes game IPC.
            // The intentional helper substitution must not be checksum-repaired
            // before CEF starts. Inhibiting this launch's bootstrap also prevents
            // a client update from replacing the shim and immediately relaunching
            // a black helper. Steam can still be updated outside a Basalt session;
            // the next compatibility install preserves that newer helper.
            arguments: [
                "-inhibitbootstrap", "-noverifyfiles", "-no-cef-sandbox",
            ],
            currentDirectory: steam.deletingLastPathComponent())
    }

    public func steamConnectionLogURL(forProfile name: String) throws -> URL? {
        let profile = try loadProfile(name)
        guard profile.source == .steam || profile.source == .bsmanager else { return nil }
        let bottle = try loadBottle(profile.bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        let candidates = [
            prefix.appendingPathComponent(
                "drive_c/Program Files (x86)/Steam/logs/connection_log.txt"),
            prefix.appendingPathComponent(
                "drive_c/Program Files/Steam/logs/connection_log.txt"),
        ]
        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
            ?? candidates[0]
    }

    public static func winePath(for hostURL: URL, prefix: URL) -> String {
        let path = hostURL.standardizedFileURL.path
        let driveC = prefix.standardizedFileURL
            .appendingPathComponent("drive_c", isDirectory: true).path
        if path == driveC {
            return #"C:\"#
        }
        if path.hasPrefix(driveC + "/") {
            return #"C:\"# + path.dropFirst(driveC.count + 1)
                .replacingOccurrences(of: "/", with: #"\"#)
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: #"\"#)
    }

    private func wineCommand(bottle: ManagedBottle, arguments: [String],
                             extraEnvironment: [String: String],
                             currentDirectory: URL? = nil) throws -> CommandOutput {
        try bottleCommand(
            bottle: bottle,
            executable: URL(fileURLWithPath: bottle.wineBinaryPath),
            arguments: arguments, extraEnvironment: extraEnvironment,
            currentDirectory: currentDirectory)
    }

    private func bottleCommand(bottle: ManagedBottle, executable: URL,
                               arguments: [String],
                               extraEnvironment: [String: String],
                               currentDirectory: URL? = nil) throws -> CommandOutput {
        var environment = extraEnvironment
        environment["WINEPREFIX"] = bottle.prefixPath
        environment["WINEARCH"] = "win64"
        environment["WINEDEBUG"] = environment["WINEDEBUG"] ?? "-all"
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw BottleToolError("Bottle executable is missing: \(executable.path)")
        }
        return try runner.run(
            executable: executable, arguments: arguments,
            environment: environment, currentDirectory: currentDirectory)
    }

    private func saveBottle(_ bottle: ManagedBottle) throws {
        let metadata = try paths.bottleMetadata(bottle.name)
        guard paths.contains(metadata) else {
            throw BottleToolError("Refusing to write bottle metadata outside the managed root")
        }
        let data = try encoder.encode(bottle)
        try data.write(to: metadata, options: .atomic)
    }

    /// Copies `source` over `destination` unless the bytes already match.
    private func copyFile(_ source: URL, to destination: URL) throws {
        let bytes = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) != bytes {
            try bytes.write(to: destination, options: .atomic)
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: source.path),
           let permissions = attributes[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: permissions],
                                           ofItemAtPath: destination.path)
        }
    }
}
