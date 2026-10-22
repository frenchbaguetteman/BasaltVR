import CryptoKit
import Foundation

/// The locally built OpenComposite and OpenVR proxy. Basalt never downloads either.
public struct VRArtifacts: Equatable, Sendable {
    public var openComposite: URL
    public var proxy: URL

    public init(openComposite: URL, proxy: URL) {
        self.openComposite = openComposite
        self.proxy = proxy
    }

    public static let openCompositeBuildCommand = "runtime/scripts/build-opencomposite.zsh"
    public static let proxyBuildCommand = "runtime/scripts/test-openvr-proxy.zsh"

    /// Why setup for `kind` cannot start yet, with the command that fixes it; nil when the
    /// files it needs exist. Only checks that they exist; Prepare VR validates their contents.
    public func missingProblem(for kind: VRRuntimeKind,
                               fileManager: FileManager = .default) -> String? {
        guard kind != .openXR else { return nil }
        if !fileManager.fileExists(atPath: openComposite.path) {
            return "OpenComposite is not built on this Mac yet. Basalt does not download it. Run \(Self.openCompositeBuildCommand) in the BasaltVR folder, then Prepare VR again."
        }
        if kind == .alyx, !fileManager.fileExists(atPath: proxy.path) {
            return "Half-Life: Alyx needs Basalt's OpenVR proxy, which is not built yet. Run \(Self.proxyBuildCommand) in the BasaltVR folder, then Prepare VR again."
        }
        return nil
    }

    /// The outputs of `build-opencomposite.zsh` and `test-openvr-proxy.zsh` in `repoRoot`.
    public static func local(repoRoot: URL) -> VRArtifacts {
        VRArtifacts(
            openComposite: repoRoot.appendingPathComponent(
                "runtime/build/opencomposite/out/openvr_api.dll"),
            proxy: repoRoot.appendingPathComponent(
                "runtime/build/openvr-proxy/bin/openvr_api.dll"))
    }
}

/// What Basalt installed for one launch profile, so it can check and undo it.
public struct VRSetupRecord: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public struct ManagedFile: Codable, Equatable, Sendable {
        public var path: String
        public var sha256: String
    }

    public struct Target: Codable, Equatable, Sendable {
        /// The game's `openvr_api.dll` (host path).
        public var dll: String
        /// `openvr_api.dll.basalt-original`, when the game had its own DLL.
        public var backup: String?
        /// Files Basalt wrote: the DLL, OpenComposite beside the proxy, and the ini.
        public var files: [ManagedFile]
        /// Copies of custom files Basalt replaced with permission. Restore keeps them.
        public var replacedCopies: [String]
    }

    public var formatVersion: Int
    public var profileName: String
    public var bottleName: String
    public var kind: VRRuntimeKind
    public var preparedAt: Date
    public var targets: [Target]
    /// Launch arguments setup added or removed, so Restore can undo them.
    public var addedArguments: [String]
    public var removedArguments: [String]
    /// The arguments before the first setup and right after the last one. Restore puts back
    /// `originalArguments` exactly while the profile still has `installedArguments`; after the
    /// user edits them it undoes only `addedArguments` and `removedArguments`.
    public var originalArguments: [String]?
    public var installedArguments: [String]?
}

public enum VRSetupStatus: Equatable, Sendable {
    /// Basalt has not prepared this game.
    case notPrepared
    /// The game is native OpenXR; no files are needed.
    case nativeOpenXR
    /// Every file Basalt installed is still in place, checked at `checked`.
    case ready(VRRuntimeKind, checked: Date)
    /// Files changed after setup (often a Steam update or file verification).
    case changed(VRRuntimeKind, issues: [String])

    public var hasRecord: Bool { self != .notPrepared }
    public var needsAttention: Bool {
        if case .changed = self { return true }
        return false
    }
}

public struct VRPrepareResult: Equatable, Sendable {
    public var kind: VRRuntimeKind
    public var targets: [URL]
    public var replacedCopies: [URL]
    public var status: VRSetupStatus
}

public struct VRRestoreReport: Equatable, Sendable {
    public var restored: [URL]
    /// Files Restore left alone: they changed after setup, or they belong to a target whose
    /// original DLL is gone.
    public var kept: [URL]
    /// Game DLLs Basalt could not put back because `openvr_api.dll.basalt-original` is
    /// missing. Their setup stays in place and recorded, so Restore can run again later.
    public var unrestored: [URL] = []

    public var isComplete: Bool { unrestored.isEmpty }
}

/// Prepare found files that Basalt did not write and will not replace without permission:
/// the game's `openvr_api.dll` (Basalt cannot tell Valve's DLL from a custom OpenComposite),
/// a custom OpenComposite beside the proxy, or an edited `opencomposite.ini`.
public struct VRCustomFilesError: LocalizedError, Equatable {
    public let files: [URL]

    public var errorDescription: String? {
        let names = files.map { "• " + $0.path }.joined(separator: "\n")
        return "Basalt did not write these files and cannot tell if they are the game's own or a custom setup, so Prepare VR changed nothing:\n\(names)\nReplace them only if you want Basalt's setup. Basalt keeps a copy of each, and Restore puts the game's openvr_api.dll back."
    }
}

extension BottleManager {
    static let openCompositeININame = "opencomposite.ini"
    static let originalSuffix = "basalt-original"

    // MARK: Locations

    /// Where the game of `profile` is installed. `steamInstallDirectory` is the game's
    /// `steamapps/common/<Game>` folder, needed when the profile starts `steam.exe -applaunch`.
    public func vrGameLocation(for profile: LaunchProfile,
                               steamInstallDirectory: URL? = nil) throws -> VRGameLocation {
        let bottle = try loadBottle(profile.bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        var appID = profile.environment["SteamAppId"]
        if let index = profile.arguments.firstIndex(of: "-applaunch"),
           profile.arguments.indices.contains(index + 1) {
            appID = profile.arguments[index + 1]
        }
        if WineProcessOwnership.isSteamClient(profile.executable) {
            guard let steamInstallDirectory else {
                throw BottleToolError(
                    "Basalt cannot find the folder of the Steam game this profile starts. Refresh the Library after Steam finishes installing it.")
            }
            var executable: URL?
            if appID == VRGameInspector.alyxAppID {
                let hlvr = steamInstallDirectory.appendingPathComponent("game/bin/win64/hlvr.exe")
                if fileManager.fileExists(atPath: hlvr.path) { executable = hlvr }
            }
            return VRGameLocation(executable: executable, folder: steamInstallDirectory,
                                  steamAppID: appID)
        }
        guard let executable = Self.hostURL(forWindowsPath: profile.executable, prefix: prefix) else {
            throw BottleToolError(
                "The game of '\(profile.name)' is not on the bottle's C: drive, so Basalt will not change its files.")
        }
        var folder = executable.deletingLastPathComponent()
        if let root = profile.gameRoot,
           let host = Self.hostURL(forWindowsPath: root, prefix: prefix) {
            folder = host
        } else if let common = Self.steamCommonFolder(of: executable) {
            folder = common
        }
        return VRGameLocation(executable: executable, folder: folder, steamAppID: appID)
    }

    /// `C:\…` inside `prefix/drive_c`, or nil for any other drive.
    static func hostURL(forWindowsPath path: String, prefix: URL) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.lowercased().hasPrefix("c:/") else { return nil }
        let relative = normalized.dropFirst(3).split(separator: "/").map(String.init)
        guard !relative.contains("..") else { return nil }
        var url = prefix.appendingPathComponent("drive_c", isDirectory: true)
        for component in relative where !component.isEmpty && component != "." {
            url.appendPathComponent(component)
        }
        return url.standardizedFileURL
    }

    static func steamCommonFolder(of executable: URL) -> URL? {
        let components = executable.pathComponents
        guard let index = components.lastIndex(where: { $0.lowercased() == "common" }),
              index > 0, components[index - 1].lowercased() == "steamapps",
              components.count > index + 2 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...(index + 1)])),
                   isDirectory: true)
    }

    // MARK: Detection

    /// Inspects a game inside `bottleName` without changing anything.
    public func inspectVRGame(_ location: VRGameLocation,
                              bottleName: String) throws -> VRGameDetection {
        let bottle = try loadBottle(bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        try requireInsideDriveC(location.folder, prefix: prefix, what: "Game folder")
        if let executable = location.executable {
            try requireInsideDriveC(executable, prefix: prefix, what: "Game executable")
        }
        return VRGameInspector.inspect(location, fileManager: fileManager)
    }

    // MARK: Prepare

    /// Makes the game reach Basalt's OpenXR runtime: OpenComposite for OpenVR games, and the
    /// proxy plus the `alyx` preset for Half-Life: Alyx. Native OpenXR games change nothing.
    ///
    /// Safe to repeat. Files Basalt did not write, including the game's first `openvr_api.dll`,
    /// stop the setup with `VRCustomFilesError` unless `replaceCustomFiles` is set; then each is
    /// kept as a new `<name>.basalt-replaced-<time>[-n]` that never replaces another file, and
    /// the first game DLL also stays in `openvr_api.dll.basalt-original`, which is never
    /// replaced. Any failure puts every touched file back.
    @discardableResult
    public func prepareVR(profileName: String, location: VRGameLocation, mode: VRMode,
                          artifacts: VRArtifacts, replaceCustomFiles: Bool = false,
                          now: Date = Date()) throws -> VRPrepareResult {
        let profile = try loadProfile(profileName)
        let detection = try inspectVRGame(location, bottleName: profile.bottleName)
        let bottle = try loadBottle(profile.bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        guard let kind = detection.resolve(mode) else {
            throw BottleToolError(
                "\(detection.summary) Choose Native OpenXR, OpenVR, or Half-Life: Alyx.")
        }
        let existing = try loadVRSetupRecord(profileName)

        if kind == .openXR {
            if let existing, !existing.targets.isEmpty {
                throw BottleToolError(
                    "This game still has the \(existing.kind.label) files from an earlier setup. Use Restore VR Files first.")
            }
            let record = VRSetupRecord(
                formatVersion: VRSetupRecord.currentFormatVersion, profileName: profileName,
                bottleName: profile.bottleName, kind: .openXR, preparedAt: now, targets: [],
                addedArguments: [], removedArguments: [])
            try saveVRSetupRecord(record)
            return VRPrepareResult(kind: .openXR, targets: [], replacedCopies: [],
                                   status: .nativeOpenXR)
        }

        let targets: [URL]
        switch kind {
        case .alyx:
            guard let executable = location.executable else {
                throw BottleToolError(
                    "Basalt cannot find hlvr.exe for this game, so it does not know where to install the proxy.")
            }
            targets = [executable.deletingLastPathComponent().appendingPathComponent("openvr_api.dll")]
        case .openVR:
            let found = detection.linkedOpenVRLibraries.isEmpty
                ? detection.openVRLibraries : detection.linkedOpenVRLibraries
            guard !found.isEmpty else {
                throw BottleToolError(
                    "No openvr_api.dll found in \(location.folder.path). If the game loads OpenVR from another folder, use Edit Launch Profile → Install a DLL by Hand.")
            }
            targets = found
        case .openXR:
            targets = []
        }
        let normalizedTargets = targets.map(\.standardizedFileURL)
        if let existing, !existing.targets.isEmpty,
           existing.kind != kind
            || Set(existing.targets.map(\.dll)) != Set(normalizedTargets.map(\.path)) {
            throw BottleToolError(
                "This game already has a \(existing.kind.label) setup for other files. Use Restore VR Files first, then Prepare VR again.")
        }

        let (openCompositeBytes, proxyBytes) = try loadArtifacts(artifacts, needsProxy: kind == .alyx)
        let machine = PEImage.machine(openCompositeBytes)!
        let configuration: OpenCompositeConfiguration = kind == .alyx ? .alyx : .standard
        let iniBytes = Data(configuration.iniText.utf8)
        let knownINIs: Set<Data> = [
            Data(OpenCompositeConfiguration.standard.iniText.utf8),
            Data(OpenCompositeConfiguration.alyx.iniText.utf8),
        ]
        var recorded = [String: String]()
        for target in existing?.targets ?? [] {
            for file in target.files { recorded[file.path] = file.sha256 }
        }
        func isOurs(_ data: Data, at url: URL, expected: Data) -> Bool {
            data == expected || recorded[url.path] == Self.sha256(data)
        }

        // Plan every write before touching anything.
        struct Write { let url: URL; let data: Data }
        var writes = [Write]()
        var custom = [URL]()
        var recordTargets = [VRSetupRecord.Target]()
        let stamp = Self.timestamp(now)
        // Files that must not exist yet: the backup and the copies. Written without overwriting.
        var newFiles = [Write]()
        var copies = [URL]()
        var reserved = Set<String>()
        func copyURL(for url: URL) -> URL {
            let base = url.path + ".basalt-replaced-\(stamp)"
            var candidate = base
            var number = 2
            while reserved.contains(candidate) || pathExists(candidate) {
                candidate = "\(base)-\(number)"
                number += 1
            }
            reserved.insert(candidate)
            return URL(fileURLWithPath: candidate)
        }

        for dll in normalizedTargets {
            try validateOpenCompositeTarget(dll, prefix: prefix)
            let directory = dll.deletingLastPathComponent()
            let backup = dll.appendingPathExtension(Self.originalSuffix)
            let proxied = directory.appendingPathComponent(Self.openCompositeProxiedDLLName)
            let ini = directory.appendingPathComponent(Self.openCompositeININame)
            for url in [dll, backup, proxied, ini] where isSymbolicLink(url) {
                throw BottleToolError(
                    "\(url.path) is a symbolic link. Basalt will not write through it.")
            }
            let dllBytes = kind == .alyx ? proxyBytes! : openCompositeBytes
            var backupPath: String?
            var targetCopies = [String]()
            func keepCopy(of url: URL, data: Data) {
                let copy = copyURL(for: url)
                newFiles.append(Write(url: copy, data: data))
                copies.append(copy)
                targetCopies.append(copy.path)
            }

            if let current = try? Data(contentsOf: dll) {
                let backupBytes = try? Data(contentsOf: backup)
                if backupBytes != nil { backupPath = backup.path }
                let ours = isOurs(current, at: dll, expected: dllBytes)
                    || current == openCompositeBytes || current == proxyBytes
                if !ours {
                    guard let gameMachine = PEImage.machine(current) else {
                        throw BottleToolError(
                            "\(dll.path) is not a Windows DLL. Basalt will not replace it.")
                    }
                    guard gameMachine == machine else {
                        throw BottleToolError(
                            "\(dll.path) is \(PEImage.describe(machine: gameMachine)), but the local OpenComposite build is \(PEImage.describe(machine: machine)). This game needs a matching OpenComposite build.")
                    }
                    if backupBytes == nil {
                        // Any x64 DLL could be Valve's or someone's own OpenComposite, so even
                        // the first replacement needs permission.
                        guard !pathExists(backup.path) else {
                            throw BottleToolError(
                                "Basalt cannot read \(backup.path), so it will not replace \(dll.lastPathComponent).")
                        }
                        custom.append(dll)
                        keepCopy(of: dll, data: current)
                        newFiles.append(Write(url: backup, data: current))
                        backupPath = backup.path
                    } else if current != backupBytes {
                        custom.append(dll)
                        keepCopy(of: dll, data: current)
                    }
                }
            } else if fileManager.fileExists(atPath: backup.path) {
                backupPath = backup.path
            }
            if kind == .alyx {
                if let current = try? Data(contentsOf: proxied),
                   !isOurs(current, at: proxied, expected: openCompositeBytes) {
                    custom.append(proxied)
                    keepCopy(of: proxied, data: current)
                }
                // The forwarding target goes first so openvr_api.dll never forwards to nothing.
                writes.append(Write(url: proxied, data: openCompositeBytes))
            }
            writes.append(Write(url: dll, data: dllBytes))
            if let current = try? Data(contentsOf: ini),
               !isOurs(current, at: ini, expected: iniBytes), !knownINIs.contains(current) {
                custom.append(ini)
                keepCopy(of: ini, data: current)
            }
            writes.append(Write(url: ini, data: iniBytes))

            var files = [VRSetupRecord.ManagedFile(path: dll.path, sha256: Self.sha256(dllBytes))]
            if kind == .alyx {
                files.append(.init(path: proxied.path, sha256: Self.sha256(openCompositeBytes)))
            }
            files.append(.init(path: ini.path, sha256: Self.sha256(iniBytes)))
            let earlier = existing?.targets.first { $0.dll == dll.path }
            recordTargets.append(VRSetupRecord.Target(
                dll: dll.path, backup: backupPath ?? earlier?.backup, files: files,
                replacedCopies: (earlier?.replacedCopies ?? []) + targetCopies))
        }
        if !custom.isEmpty && !replaceCustomFiles {
            throw VRCustomFilesError(files: custom)
        }

        // Launch arguments: Alyx starts in VR on D3D11 (DXMT has no Vulkan path to Basalt).
        var updatedProfile = profile
        var added = existing?.addedArguments ?? []
        var removed = existing?.removedArguments ?? []
        if kind == .alyx {
            let change = Self.alyxArguments(profile.arguments)
            updatedProfile.arguments = change.arguments
            added += change.added
            removed += change.removed
        }
        // The exact original survives a repeat only while nobody edited the arguments since.
        var originalArguments: [String]? = profile.arguments
        if let existing {
            originalArguments = existing.installedArguments == profile.arguments
                ? existing.originalArguments : nil
        }

        let transaction = FileTransaction(fileManager: fileManager)
        do {
            for write in newFiles {
                try transaction.create(write.data, at: write.url)
            }
            for write in writes {
                try transaction.write(write.data, to: write.url)
            }
            if updatedProfile != profile {
                try transaction.write(encoder.encode(updatedProfile),
                                      to: paths.profileFile(profileName))
            }
            let record = VRSetupRecord(
                formatVersion: VRSetupRecord.currentFormatVersion, profileName: profileName,
                bottleName: profile.bottleName, kind: kind, preparedAt: now,
                targets: recordTargets, addedArguments: added, removedArguments: removed,
                originalArguments: originalArguments, installedArguments: updatedProfile.arguments)
            try fileManager.createDirectory(at: paths.vrSetups, withIntermediateDirectories: true)
            try transaction.write(encoder.encode(record), to: paths.vrSetupFile(profileName))
            let status = vrSetupStatus(profileName: profileName, now: now)
            guard case .ready = status else {
                throw BottleToolError("Basalt could not confirm the VR files after writing them.")
            }
            return VRPrepareResult(
                kind: kind, targets: normalizedTargets,
                replacedCopies: copies, status: status)
        } catch {
            transaction.rollBack()
            throw error
        }
    }

    /// Removes hello_xr test flags (each with a value hello_xr knows) and `-vulkan`, and adds
    /// `-vr -dx11` when missing.
    static func alyxArguments(_ arguments: [String])
        -> (arguments: [String], added: [String], removed: [String]) {
        let helloXRFlags: [Set<String>: Set<String>] = [
            ["-g", "--graphics"]: ["d3d11", "d3d12", "vulkan", "vulkan2", "opengl", "opengles"],
            ["-ff", "--formfactor"]: ["hmd", "handheld"],
            ["-vc", "--viewconfig"]: ["stereo", "mono"],
            ["-bm", "--blendmode"]: ["opaque", "additive", "alphablend"],
            ["-s", "--space"]: ["view", "local", "stage", "stageleft", "stageright",
                                "stageleftrotated", "stagerightrotated"],
        ]
        var result = [String]()
        var removed = [String]()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-applaunch", index + 1 < arguments.count {
                result += [argument, arguments[index + 1]]
                index += 2
                continue
            }
            if let values = helloXRFlags.first(where: { $0.key.contains(argument.lowercased()) })?.value,
               index + 1 < arguments.count, values.contains(arguments[index + 1].lowercased()) {
                removed += [argument, arguments[index + 1]]
                index += 2
                continue
            }
            if argument.lowercased() == "-vulkan" {
                removed.append(argument)
                index += 1
                continue
            }
            result.append(argument)
            index += 1
        }
        var added = [String]()
        for flag in ["-vr", "-dx11"] where !result.contains(where: { $0.lowercased() == flag }) {
            result.append(flag)
            added.append(flag)
        }
        return (result, added, removed)
    }

    // MARK: Status

    public func loadVRSetupRecord(_ profileName: String) throws -> VRSetupRecord? {
        let file = try paths.vrSetupFile(profileName)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let record = try decoder.decode(VRSetupRecord.self, from: data)
        guard record.formatVersion == VRSetupRecord.currentFormatVersion,
              record.profileName == profileName else {
            throw BottleToolError("The VR setup record of '\(profileName)' is not valid")
        }
        return record
    }

    func saveVRSetupRecord(_ record: VRSetupRecord) throws {
        try fileManager.createDirectory(at: paths.vrSetups, withIntermediateDirectories: true)
        try encoder.encode(record).write(
            to: paths.vrSetupFile(record.profileName), options: .atomic)
    }

    /// Checks every file Basalt installed against the hash it recorded. Never cached: a Steam
    /// update or "Verify integrity" can put Valve's DLL back at any time.
    public func vrSetupStatus(profileName: String, now: Date = Date()) -> VRSetupStatus {
        guard let record = try? loadVRSetupRecord(profileName) else { return .notPrepared }
        if record.kind == .openXR { return .nativeOpenXR }
        var issues = [String]()
        for target in record.targets {
            for file in target.files {
                let url = URL(fileURLWithPath: file.path)
                if isSymbolicLink(url) {
                    issues.append("\(url.lastPathComponent) became a symbolic link")
                } else if let data = try? Data(contentsOf: url) {
                    if Self.sha256(data) != file.sha256 {
                        issues.append("\(url.lastPathComponent) changed in \(url.deletingLastPathComponent().lastPathComponent)")
                    }
                } else {
                    issues.append("\(url.lastPathComponent) is missing in \(url.deletingLastPathComponent().lastPathComponent)")
                }
            }
        }
        if record.targets.isEmpty { issues.append("No files are recorded") }
        return issues.isEmpty ? .ready(record.kind, checked: now)
            : .changed(record.kind, issues: issues)
    }

    // MARK: Restore

    /// Puts the game's own files back and removes what Basalt installed. Files that changed after
    /// setup are left alone and reported. Custom-file copies are kept. When a target's
    /// `openvr_api.dll.basalt-original` is gone, that target keeps its whole setup (DLL, proxied
    /// OpenComposite, ini), the record keeps it, and the launch arguments stay, so the game still
    /// has a working setup and Restore can run again once the original is back.
    @discardableResult
    public func restoreVR(profileName: String) throws -> VRRestoreReport {
        guard var record = try loadVRSetupRecord(profileName) else {
            throw BottleToolError("'\(profileName)' has no VR setup to restore.")
        }
        let bottle = try loadBottle(record.bottleName)
        let prefix = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        var restored = [URL]()
        var kept = [URL]()
        var unrestored = [URL]()
        var remaining = [VRSetupRecord.Target]()
        let transaction = FileTransaction(fileManager: fileManager)
        do {
            for target in record.targets {
                let dll = URL(fileURLWithPath: target.dll).standardizedFileURL
                try validateOpenCompositeTarget(dll, prefix: prefix)
                let directory = dll.deletingLastPathComponent()
                let allowed: Set<String> = [
                    dll.path,
                    directory.appendingPathComponent(Self.openCompositeProxiedDLLName).path,
                    directory.appendingPathComponent(Self.openCompositeININame).path,
                ]
                let backup = dll.appendingPathExtension(Self.originalSuffix)
                guard target.files.allSatisfy({ allowed.contains($0.path) }),
                      target.backup == nil || target.backup == backup.path else {
                    throw BottleToolError("The VR setup record of '\(profileName)' names unexpected files")
                }
                for url in [dll, backup] + allowed.map({ URL(fileURLWithPath: $0) })
                where isSymbolicLink(url) {
                    throw BottleToolError("\(url.path) is a symbolic link. Basalt will not change it.")
                }
                let backupBytes = target.backup.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
                let installedDLL = target.files.first { $0.path == dll.path }
                if target.backup != nil, backupBytes == nil, let installedDLL,
                   let current = try? Data(contentsOf: dll), Self.sha256(current) == installedDLL.sha256 {
                    // The game's own DLL is gone. Removing Basalt's, or the files it needs,
                    // would leave the game with a broken setup.
                    unrestored.append(dll)
                    kept += target.files.map { URL(fileURLWithPath: $0.path) }
                        .filter { fileManager.fileExists(atPath: $0.path) }
                    remaining.append(target)
                    continue
                }
                for file in target.files {
                    let url = URL(fileURLWithPath: file.path)
                    guard let current = try? Data(contentsOf: url) else { continue }
                    if Self.sha256(current) == file.sha256 {
                        if url == dll, let backupBytes {
                            try transaction.write(backupBytes, to: dll)
                            try transaction.remove(backup)
                        } else {
                            try transaction.remove(url)
                        }
                        restored.append(url)
                    } else if url == dll, let backupBytes, current == backupBytes {
                        // A Steam update or file check already put the game's DLL back.
                        try transaction.remove(backup)
                        restored.append(url)
                    } else {
                        kept.append(url)
                    }
                }
            }
            if remaining.isEmpty {
                if var profile = try? loadProfile(profileName) {
                    let arguments = Self.restoredArguments(profile.arguments, record: record)
                    if arguments != profile.arguments {
                        profile.arguments = arguments
                        try transaction.write(encoder.encode(profile), to: paths.profileFile(profileName))
                    }
                }
                try transaction.remove(paths.vrSetupFile(profileName))
            } else {
                record.targets = remaining
                try transaction.write(encoder.encode(record), to: paths.vrSetupFile(profileName))
            }
        } catch {
            transaction.rollBack()
            throw error
        }
        return VRRestoreReport(restored: restored, kept: kept, unrestored: unrestored)
    }

    /// The exact arguments from before setup while the profile still has the ones setup left;
    /// otherwise the user's current arguments without `addedArguments`, with
    /// `removedArguments` (flags still next to their values) at the end.
    static func restoredArguments(_ current: [String], record: VRSetupRecord) -> [String] {
        if let original = record.originalArguments, current == record.installedArguments {
            return original
        }
        var arguments = current
        for flag in record.addedArguments {
            if let index = arguments.firstIndex(of: flag) { arguments.remove(at: index) }
        }
        return arguments + record.removedArguments
    }

    // MARK: Helpers

    private func loadArtifacts(_ artifacts: VRArtifacts,
                               needsProxy: Bool) throws -> (Data, Data?) {
        if let problem = artifacts.missingProblem(for: needsProxy ? .alyx : .openVR,
                                                  fileManager: fileManager) {
            throw BottleToolError(problem)
        }
        let openComposite = try Data(contentsOf: artifacts.openComposite)
        guard let machine = PEImage.machine(openComposite) else {
            throw BottleToolError("\(artifacts.openComposite.path) is not a Windows DLL. Build OpenComposite again with \(VRArtifacts.openCompositeBuildCommand).")
        }
        guard machine == PEImage.machineX64 else {
            throw BottleToolError("The local OpenComposite build is \(PEImage.describe(machine: machine)); Basalt needs a 64-bit (x86-64) build.")
        }
        guard needsProxy else { return (openComposite, nil) }
        let proxy = try Data(contentsOf: artifacts.proxy)
        guard PEImage.machine(proxy) == machine else {
            throw BottleToolError("The OpenVR proxy at \(artifacts.proxy.path) is not a 64-bit (x86-64) Windows DLL. Build it again with \(VRArtifacts.proxyBuildCommand).")
        }
        return (openComposite, proxy)
    }

    /// `url` is below `prefix/drive_c`, and so is every existing folder on its path after
    /// symbolic links are resolved. A folder on the path may be a link that stays inside
    /// drive_c; Prepare and Restore separately refuse files that are links themselves, and
    /// create backups and copies only where nothing exists yet.
    func requireInsideDriveC(_ url: URL, prefix: URL, what: String) throws {
        let driveC = prefix.standardizedFileURL.appendingPathComponent("drive_c").path
        let candidate = url.standardizedFileURL
        guard candidate.path.hasPrefix(driveC + "/") else {
            throw BottleToolError("\(what) must be inside the bottle's drive_c folder")
        }
        var ancestor = candidate
        while !fileManager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
        }
        let resolvedDriveC = URL(fileURLWithPath: driveC).resolvingSymlinksInPath().path
        let resolved = ancestor.resolvingSymlinksInPath().path
        guard resolved == resolvedDriveC || resolved.hasPrefix(resolvedDriveC + "/") else {
            throw BottleToolError("\(what) resolves outside the bottle's drive_c folder")
        }
    }

    /// A game `openvr_api.dll` that Basalt may write: inside the prefix after resolving links,
    /// named `openvr_api.dll`, in an existing folder.
    func validateOpenCompositeTarget(_ dll: URL, prefix: URL) throws {
        try requireInsideDriveC(dll, prefix: prefix, what: "OpenComposite target")
        guard dll.lastPathComponent.lowercased() == "openvr_api.dll" else {
            throw BottleToolError("OpenComposite target must be named openvr_api.dll")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dll.deletingLastPathComponent().path,
                                     isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BottleToolError("The folder of \(dll.path) does not exist")
        }
    }

    /// Something is at `path`, even a link to nothing.
    func pathExists(_ path: String) -> Bool {
        (try? fileManager.attributesOfItem(atPath: path)) != nil
    }

    func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

/// Writes and removes files, remembering what each path held first so a failure can put
/// everything back.
final class FileTransaction {
    private let fileManager: FileManager
    private var originals = [(URL, Data?)]()
    private var seen = Set<String>()

    init(fileManager: FileManager) { self.fileManager = fileManager }

    private func remember(_ url: URL) {
        guard seen.insert(url.path).inserted else { return }
        originals.append((url, try? Data(contentsOf: url)))
    }

    func write(_ data: Data, to url: URL) throws {
        remember(url)
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }

    /// Writes a file that must not exist yet. Fails, without touching it, if anything is
    /// already at `url`, including a link or a folder.
    func create(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        if seen.insert(url.path).inserted { originals.append((url, nil)) }
    }

    func remove(_ url: URL) throws {
        remember(url)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func rollBack() {
        for (url, data) in originals.reversed() {
            if let data {
                try? data.write(to: url, options: .atomic)
            } else {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
