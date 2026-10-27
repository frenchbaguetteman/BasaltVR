import Foundation
import BasaltBottleKit

private struct ArgumentCursor {
    private(set) var values: [String]
    /// Arguments after `--`, held apart so option lookups never consume
    /// game arguments such as `-- --root x`.
    private var trailing: [String]?

    init(_ arguments: [String]) {
        guard let separator = arguments.firstIndex(of: "--") else {
            values = arguments
            return
        }
        values = Array(arguments[..<separator])
        trailing = Array(arguments[(separator + 1)...])
    }

    var remainder: [String] { values + (trailing.map { ["--"] + $0 } ?? []) }

    mutating func pop() -> String? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }

    mutating func require(_ description: String) throws -> String {
        guard let value = pop() else {
            throw BottleToolError("Missing \(description)")
        }
        return value
    }

    mutating func value(after option: String) throws -> String? {
        guard let index = values.firstIndex(of: option) else { return nil }
        guard index + 1 < values.count else {
            throw BottleToolError("Missing value after \(option)")
        }
        let value = values[index + 1]
        values.removeSubrange(index...index + 1)
        return value
    }

    mutating func repeatedValues(after option: String) throws -> [String] {
        var found = [String]()
        while let value = try value(after: option) { found.append(value) }
        return found
    }

    mutating func takeTrailingValues() -> [String] {
        defer { trailing = nil }
        return trailing ?? []
    }
}

@main
private struct BasaltCLI {
    static let usage = """
    BasaltVR M5 bottle and launch-profile CLI

    Usage:
      basaltctl [--root PATH] [--repo PATH] doctor
      basaltctl [--root PATH] [--repo PATH] engines
      basaltctl [--root PATH] [--repo PATH] bottle list
      basaltctl [--root PATH] [--repo PATH] bottle create NAME --engine ENGINE_ID
      basaltctl [--root PATH] [--repo PATH] bottle prepare NAME
      basaltctl [--root PATH] [--repo PATH] bottle install-dxmt NAME
      basaltctl [--root PATH] [--repo PATH] bottle install-runtime NAME
      basaltctl [--root PATH] [--repo PATH] bottle verify NAME
      basaltctl [--root PATH] [--repo PATH] profile list
      basaltctl [--root PATH] [--repo PATH] profile show NAME
      basaltctl [--root PATH] [--repo PATH] profile add NAME --bottle BOTTLE \
        --source direct|steam|bsmanager|itch --exe PATH [--cwd PATH] \
        [--arg VALUE ...] [--env KEY=VALUE ...] [--game-root PATH]
      basaltctl [--root PATH] [--repo PATH] opencomposite install PROFILE \
        --artifact /path/openvr_api.dll --target /managed/prefix/.../openvr_api.dll \
        [--proxy /path/basalt/openvr_api.dll] [--preset default|alyx] \
        [--ini KEY=VALUE ...]
      basaltctl [--root PATH] [--repo PATH] run PROFILE --control-file PATH [-- ARG ...]
      basaltctl [--root PATH] [--repo PATH] steam start PROFILE [--log PATH]

    `bottle prepare` installs the Basalt DXMT fork and OpenXR runtime into an
    existing managed pinned-engine bottle. OpenComposite is deliberately supplied
    by the user and remains a separate GPLv3 artifact. With --proxy, the Basalt
    proxy becomes openvr_api.dll and OpenComposite is installed beside it as
    openvr_api_opencomposite.dll; Half-Life: Alyx needs --proxy and --preset alyx.
    """

    static func main() {
        do {
            var cursor = ArgumentCursor(Array(CommandLine.arguments.dropFirst()))
            if cursor.values == ["--help"] || cursor.values == ["help"] ||
                cursor.remainder.isEmpty {
                print(usage)
                return
            }
            let rootOverride = try cursor.value(after: "--root")
            let repoOverride = try cursor.value(after: "--repo")
            let repoRoot = try repoOverride.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? discoverRepoRoot()
            let root = rootOverride.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? BottleManager.defaultRoot()
            let manager = BottleManager(root: root, repoRoot: repoRoot)
            let command = try cursor.require("command")
            switch command {
            case "doctor":
                try doctor(manager, root: root, repoRoot: repoRoot)
            case "engines":
                printEngines(manager.engines())
            case "bottle":
                try bottleCommand(&cursor, manager: manager)
            case "profile":
                try profileCommand(&cursor, manager: manager)
            case "opencomposite":
                try openCompositeCommand(&cursor, manager: manager)
            case "run":
                try runCommand(&cursor, manager: manager)
            case "steam":
                try steamCommand(&cursor, manager: manager)
            default:
                throw BottleToolError("Unknown command '\(command)'\n\n\(usage)")
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func discoverRepoRoot() throws -> URL {
        let discoveryError: Error
        do {
            return try RepositoryLocator.find()
        } catch {
            discoveryError = error
        }

        let packagedSupport = Bundle.main.resourceURL?
            .appendingPathComponent("BasaltVR", isDirectory: true)
        let candidates = [
            packagedSupport,
            Bundle.main.executableURL,
        ].compactMap { $0 }

        if let bundled = candidates.lazy.compactMap({
            try? RepositoryLocator.find(startingAt: $0, environment: [:])
        }).first {
            return bundled
        }

        throw discoveryError
    }

    private static func doctor(_ manager: BottleManager, root: URL,
                               repoRoot: URL) throws {
        try manager.prepare()
        print("Managed root: \(root.standardizedFileURL.path)")
        print("Repository:   \(repoRoot.standardizedFileURL.path)")
        printEngines(manager.engines())
        let runtime = repoRoot.appendingPathComponent("runtime/build/bin/basalt_openxr.dll")
        let fork = repoRoot.appendingPathComponent(
            "runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so")
        print("OpenXR DLL:   \(FileManager.default.fileExists(atPath: runtime.path) ? "ready" : "missing")")
        print("DXMT fork:    \(FileManager.default.fileExists(atPath: fork.path) ? "ready" : "missing")")
    }

    private static func printEngines(_ engines: [BottleEngine]) {
        if engines.isEmpty {
            print("No supported Wine engines found.")
            return
        }
        for engine in engines {
            print("\(engine.id)\t\(engine.kind.rawValue)\tDXMT=\(engine.supportsBasaltDXMT ? "yes" : "no")\t\(engine.wineBinary.path)")
        }
    }

    private static func bottleCommand(_ cursor: inout ArgumentCursor,
                                      manager: BottleManager) throws {
        let operation = try cursor.require("bottle operation")
        switch operation {
        case "list":
            let bottles = try manager.listBottles()
            if bottles.isEmpty { print("No managed bottles.") }
            for bottle in bottles {
                print("\(bottle.name)\t\(bottle.engineID)\tDXMT=\(yesNo(bottle.dxmtInstalled))\truntime=\(yesNo(bottle.runtimeInstalled))")
            }
        case "create":
            let name = try cursor.require("bottle name")
            guard let engine = try cursor.value(after: "--engine") else {
                throw BottleToolError("bottle create requires --engine ENGINE_ID")
            }
            try rejectRemainder(cursor)
            let bottle = try manager.createBottle(name: name, engineID: engine)
            print("Created managed bottle '\(bottle.name)' at \(bottle.prefixPath)")
        case "prepare":
            let name = try cursor.require("bottle name")
            try rejectRemainder(cursor)
            _ = try manager.installDXMT(in: name)
            _ = try manager.installRuntime(in: name)
            print(try manager.verify(name))
        case "install-dxmt":
            let name = try cursor.require("bottle name")
            try rejectRemainder(cursor)
            let bottle = try manager.installDXMT(in: name)
            print("Installed Basalt DXMT into '\(bottle.name)'")
        case "install-runtime":
            let name = try cursor.require("bottle name")
            try rejectRemainder(cursor)
            let bottle = try manager.installRuntime(in: name)
            print("Installed and registered Basalt OpenXR in '\(bottle.name)'")
        case "verify":
            let name = try cursor.require("bottle name")
            try rejectRemainder(cursor)
            print(try manager.verify(name))
        default:
            throw BottleToolError("Unknown bottle operation '\(operation)'")
        }
    }

    private static func profileCommand(_ cursor: inout ArgumentCursor,
                                       manager: BottleManager) throws {
        let operation = try cursor.require("profile operation")
        switch operation {
        case "list":
            let profiles = try manager.listProfiles()
            if profiles.isEmpty { print("No launch profiles.") }
            for profile in profiles {
                print("\(profile.name)\t\(profile.source.rawValue)\t\(profile.bottleName)\t\(profile.executable)")
            }
        case "show":
            let name = try cursor.require("profile name")
            try rejectRemainder(cursor)
            let profile = try manager.loadProfile(name)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(profile), as: UTF8.self))
        case "add":
            let name = try cursor.require("profile name")
            guard let bottle = try cursor.value(after: "--bottle"),
                  let sourceValue = try cursor.value(after: "--source"),
                  let source = LaunchSource(rawValue: sourceValue),
                  let executable = try cursor.value(after: "--exe") else {
                throw BottleToolError(
                    "profile add requires --bottle, a valid --source, and --exe")
            }
            let cwd = try cursor.value(after: "--cwd")
            let gameRoot = try cursor.value(after: "--game-root")
            let arguments = try cursor.repeatedValues(after: "--arg")
            let environmentValues = try cursor.repeatedValues(after: "--env")
            var environment = [String: String]()
            for entry in environmentValues {
                guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else {
                    throw BottleToolError("Invalid --env '\(entry)'; expected KEY=VALUE")
                }
                environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
            try rejectRemainder(cursor)
            let profile = LaunchProfile(
                name: name, bottleName: bottle, source: source,
                executable: executable, arguments: arguments,
                workingDirectory: cwd, environment: environment,
                gameRoot: gameRoot)
            try manager.saveProfile(profile)
            print("Saved launch profile '\(name)'")
        default:
            throw BottleToolError("Unknown profile operation '\(operation)'")
        }
    }

    private static func openCompositeCommand(_ cursor: inout ArgumentCursor,
                                             manager: BottleManager) throws {
        let operation = try cursor.require("OpenComposite operation")
        guard operation == "install" else {
            throw BottleToolError("Unknown OpenComposite operation '\(operation)'")
        }
        let profile = try cursor.require("profile name")
        guard let artifact = try cursor.value(after: "--artifact"),
              let target = try cursor.value(after: "--target") else {
            throw BottleToolError(
                "opencomposite install requires --artifact and --target")
        }
        let proxy = try cursor.value(after: "--proxy")
        let presetName = try cursor.value(after: "--preset") ?? "default"
        guard let preset = OpenCompositeConfiguration.Preset(rawValue: presetName) else {
            let names = OpenCompositeConfiguration.Preset.allCases.map(\.rawValue)
            throw BottleToolError(
                "Unknown OpenComposite preset '\(presetName)'; use \(names.joined(separator: " or "))")
        }
        let assignments = try cursor.repeatedValues(after: "--ini")
        try rejectRemainder(cursor)
        if preset == .alyx, proxy == nil {
            throw BottleToolError(
                "--preset alyx requires --proxy: Half-Life: Alyx needs Valve's VRControlPanel export, which OpenComposite lacks")
        }
        var configuration = OpenCompositeConfiguration(preset: preset)
        for assignment in assignments { try configuration.apply(assignment) }
        let installed = try manager.installOpenComposite(
            profileName: profile, artifact: URL(fileURLWithPath: artifact),
            targetDLL: URL(fileURLWithPath: target),
            proxy: proxy.map { URL(fileURLWithPath: $0) },
            configuration: configuration)
        if proxy != nil {
            print("Installed the OpenVR proxy at \(installed.path)")
            print("Installed OpenComposite at \(installed.deletingLastPathComponent().appendingPathComponent(BottleManager.openCompositeProxiedDLLName).path)")
        } else {
            print("Installed OpenComposite at \(installed.path)")
        }
    }

    private static func runCommand(_ cursor: inout ArgumentCursor,
                                   manager: BottleManager) throws {
        let profile = try cursor.require("profile name")
        guard let control = try cursor.value(after: "--control-file") else {
            throw BottleToolError("run requires --control-file PATH")
        }
        let additional = cursor.takeTrailingValues()
        try rejectRemainder(cursor)
        let result = try manager.runProfile(
            profile, controlFile: URL(fileURLWithPath: control),
            additionalArguments: additional)
        if !result.output.isEmpty { print(result.output, terminator: "") }
        guard result.status == 0 else {
            throw BottleToolError("Profile '\(profile)' exited with status \(result.status)")
        }
    }

    /// `steam start PROFILE`: installs the Steam web helper compatibility shim
    /// (black Steam window fix), then starts Steam with the Basalt flags and
    /// returns at once. Steam keeps running after this command ends.
    private static func steamCommand(_ cursor: inout ArgumentCursor,
                                     manager: BottleManager) throws {
        let action = try cursor.require("steam action")
        guard action == "start" else {
            throw BottleToolError("Unknown steam action '\(action)' (use: start)")
        }
        let profile = try cursor.require("profile name")
        let log = try cursor.value(after: "--log")
        try rejectRemainder(cursor)
        guard try manager.installSteamWebHelperCompatibility(forProfile: profile) != nil,
              let command = try manager.steamBootstrapCommand(forProfile: profile) else {
            throw BottleToolError("Profile '\(profile)' is not a Steam profile")
        }
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectory
        var environment = ProcessInfo.processInfo.environment
        command.environment.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        if let log {
            FileManager.default.createFile(atPath: log, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        print("Started Steam (pid \(process.processIdentifier))")
    }

    private static func rejectRemainder(_ cursor: ArgumentCursor) throws {
        guard cursor.remainder.isEmpty else {
            throw BottleToolError("Unexpected arguments: \(cursor.remainder.joined(separator: " "))")
        }
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}
