import XCTest
@testable import BasaltBottleKit

final class VRSetupTests: XCTestCase {
    private var temporary: URL!
    private var manager: BottleManager!
    private var prefix: URL!
    private var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }
    private var artifacts: VRArtifacts!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent(
            "BasaltVRSetup-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Test", isDirectory: true)
        prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        try fm.createDirectory(at: engineRoot.appendingPathComponent("bin"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: driveC, withIntermediateDirectories: true)
        let engine = BottleEngine(
            id: "test-pinned", kind: .pinned,
            wineBinary: engineRoot.appendingPathComponent("bin/wine"),
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        let bottle = ManagedBottle(
            name: "Test", engine: engine, prefix: prefix, engineRoot: engineRoot,
            wineBinary: engineRoot.appendingPathComponent("bin/wine"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        manager = BottleManager(root: root, repoRoot: temporary.appendingPathComponent("repo"))

        artifacts = VRArtifacts.local(repoRoot: temporary.appendingPathComponent("repo"))
        try fm.createDirectory(at: artifacts.openComposite.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: artifacts.proxy.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Self.pe(marker: 0xc0).write(to: artifacts.openComposite)
        try Self.pe(marker: 0xc1).write(to: artifacts.proxy)
    }

    override func tearDownWithError() throws {
        if let temporary {
            _ = try? fm.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: temporary.appendingPathComponent("locked").path)
            try? fm.removeItem(at: temporary)
        }
    }

    /// A minimal PE32+ image with an import table naming `imports`.
    static func pe(machine: UInt16 = 0x8664, imports: [String] = [], marker: UInt8) -> Data {
        var image = [UInt8](repeating: 0, count: 0x400)
        func put16(_ value: UInt16, _ at: Int) {
            image[at] = UInt8(value & 0xff); image[at + 1] = UInt8(value >> 8)
        }
        func put32(_ value: UInt32, _ at: Int) {
            for i in 0..<4 { image[at + i] = UInt8((value >> (8 * UInt32(i))) & 0xff) }
        }
        image[0] = 0x4d; image[1] = 0x5a
        put32(0x40, 0x3c)
        image[0x40] = 0x50; image[0x41] = 0x45
        put16(machine, 0x44)
        put16(1, 0x46)            // one section
        put16(240, 0x54)          // optional header size
        let optional = 0x58
        put16(0x20b, optional)
        put32(16, optional + 108) // NumberOfRvaAndSizes
        if !imports.isEmpty {
            put32(0x1000, optional + 120)
            put32(UInt32(20 * (imports.count + 1)), optional + 124)
        }
        let section = optional + 240
        put32(0x200, section + 8)   // VirtualSize
        put32(0x1000, section + 12) // VirtualAddress
        put32(0x200, section + 16)  // SizeOfRawData
        put32(0x200, section + 20)  // PointerToRawData
        for (index, name) in imports.enumerated() {
            let descriptor = 0x200 + 20 * index
            put32(1, descriptor)
            put32(UInt32(0x1100 + 32 * index), descriptor + 12)
            put32(1, descriptor + 16)
            for (offset, byte) in name.utf8.enumerated() {
                image[0x300 + 32 * index + offset] = byte
            }
        }
        image[0x3ff] = marker
        return Data(image)
    }

    private func write(_ data: Data, _ relative: String) throws -> URL {
        let url = driveC.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func saveProfile(_ name: String, executable: String, arguments: [String] = [],
                             environment: [String: String] = [:]) throws {
        try manager.saveProfile(LaunchProfile(
            name: name, bottleName: "Test", source: .direct, executable: executable,
            arguments: arguments, environment: environment))
    }

    private func alyxFixture() throws -> (VRGameLocation, URL, Data) {
        let bin = "Program Files (x86)/Steam/steamapps/common/Half-Life Alyx/game/bin/win64"
        let exe = try write(Self.pe(marker: 1), "\(bin)/hlvr.exe")
        let valve = Self.pe(marker: 0x56)
        let dll = try write(valve, "\(bin)/openvr_api.dll")
        try saveProfile(
            "alyx",
            executable: #"C:\Program Files (x86)\Steam\steamapps\common\Half-Life Alyx\game\bin\win64\hlvr.exe"#,
            arguments: ["-novid", "-g", "D3D11", "-vulkan"])
        let location = try manager.vrGameLocation(for: manager.loadProfile("alyx"))
        XCTAssertEqual(location.executable, exe.standardizedFileURL)
        XCTAssertEqual(location.folder.lastPathComponent, "Half-Life Alyx")
        return (location, dll, valve)
    }

    // MARK: - PE parsing

    func testPEImageReadsMachineAndImports() {
        let image = Self.pe(imports: ["KERNEL32.dll", "openvr_api.dll"], marker: 0)
        XCTAssertEqual(PEImage.machine(image), PEImage.machineX64)
        XCTAssertEqual(PEImage.importedLibraries(image), ["kernel32.dll", "openvr_api.dll"])
        XCTAssertEqual(PEImage.machine(Self.pe(machine: 0x014c, marker: 0)), PEImage.machineX86)
        XCTAssertTrue(PEImage.importedLibraries(Data([0x4d, 0x5a, 1, 2])).isEmpty)
        // A truncated image must not crash.
        XCTAssertTrue(PEImage.importedLibraries(image.prefix(0x210)).isEmpty
                      || PEImage.importedLibraries(image.prefix(0x210)).count <= 2)
    }

    // MARK: - Detection

    func testDetectionKnowsAlyxByExecutableAndSteamAppID() throws {
        let (location, _, _) = try alyxFixture()
        XCTAssertEqual(VRGameInspector.inspect(location).verdict, .knownAlyx)
        let byAppID = VRGameLocation(executable: nil, folder: location.folder, steamAppID: "546560")
        XCTAssertEqual(VRGameInspector.inspect(byAppID).suggestedKind, .alyx)
    }

    func testDetectionNeedsEvidenceThatTheExecutableLoadsOpenVR() throws {
        // A DLL beside an executable that does not import it is only "nearby".
        let exe = try write(Self.pe(marker: 1), "Games/Nearby/game.exe")
        _ = try write(Self.pe(marker: 2), "Games/Nearby/openvr_api.dll")
        let nearby = VRGameInspector.inspect(VRGameLocation(
            executable: exe, folder: exe.deletingLastPathComponent()))
        XCTAssertEqual(nearby.verdict, .uncertain)
        XCTAssertNil(nearby.suggestedKind)
        XCTAssertEqual(nearby.openVRLibraries.count, 1)

        // The same layout with an import is confirmed.
        let importing = try write(Self.pe(imports: ["openvr_api.dll"], marker: 3),
                                  "Games/Linked/game.exe")
        _ = try write(Self.pe(marker: 2), "Games/Linked/openvr_api.dll")
        XCTAssertEqual(VRGameInspector.inspect(VRGameLocation(
            executable: importing, folder: importing.deletingLastPathComponent())).verdict, .openVR)

        // Unity loads native plugins from <Exe>_Data/Plugins.
        let unity = try write(Self.pe(marker: 4), "Games/Unity/Unity Game.exe")
        _ = try write(Self.pe(marker: 2), "Games/Unity/Unity Game_Data/Plugins/x86_64/openvr_api.dll")
        _ = try write(Self.pe(marker: 2), "Games/Unity/Other_Data/Plugins/openvr_api.dll")
        let unityDetection = VRGameInspector.inspect(VRGameLocation(
            executable: unity, folder: unity.deletingLastPathComponent()))
        XCTAssertEqual(unityDetection.verdict, .openVR)
        XCTAssertEqual(unityDetection.linkedOpenVRLibraries.count, 1)
        XCTAssertEqual(unityDetection.openVRLibraries.count, 2)
    }

    func testDetectionNativeOpenXRAndMixedAndEmpty() throws {
        let openXR = try write(Self.pe(marker: 1), "Games/XR/XR.exe")
        _ = try write(Self.pe(marker: 2), "Games/XR/XR_Data/Plugins/x86_64/openxr_loader.dll")
        XCTAssertEqual(VRGameInspector.inspect(VRGameLocation(
            executable: openXR, folder: openXR.deletingLastPathComponent())).suggestedKind, .openXR)

        _ = try write(Self.pe(marker: 2), "Games/XR/XR_Data/Plugins/x86_64/openvr_api.dll")
        XCTAssertEqual(VRGameInspector.inspect(VRGameLocation(
            executable: openXR, folder: openXR.deletingLastPathComponent())).verdict, .uncertain)

        let flat = try write(Self.pe(marker: 1), "Games/Flat/flat.exe")
        XCTAssertEqual(VRGameInspector.inspect(VRGameLocation(
            executable: flat, folder: flat.deletingLastPathComponent())).verdict, .nothingFound)
    }

    func testDetectionDoesNotFollowSymbolicLinks() throws {
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Self.pe(marker: 2).write(to: outside.appendingPathComponent("openvr_api.dll"))
        let exe = try write(Self.pe(marker: 1), "Games/Linky/game.exe")
        try fm.createSymbolicLink(at: exe.deletingLastPathComponent().appendingPathComponent("libs"),
                                  withDestinationURL: outside)
        try fm.createSymbolicLink(
            at: exe.deletingLastPathComponent().appendingPathComponent("openvr_api.dll"),
            withDestinationURL: outside.appendingPathComponent("openvr_api.dll"))
        let detection = VRGameInspector.inspect(VRGameLocation(
            executable: exe, folder: exe.deletingLastPathComponent()))
        XCTAssertEqual(detection.verdict, .nothingFound)
    }

    // MARK: - Alyx

    func testAlyxPrepareInstallsProxyPresetAndArgumentsAndRepeatsSafely() throws {
        let (location, dll, valve) = try alyxFixture()
        let directory = dll.deletingLastPathComponent()
        let backup = dll.appendingPathExtension("basalt-original")
        let proxied = directory.appendingPathComponent("openvr_api_opencomposite.dll")
        let ini = directory.appendingPathComponent("opencomposite.ini")

        // Basalt cannot tell Valve's DLL from a custom one, so the first setup asks.
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "alyx", location: location, mode: .auto, artifacts: artifacts)) {
            XCTAssertEqual(($0 as? VRCustomFilesError)?.files, [dll.standardizedFileURL])
        }
        let result = try manager.prepareVR(
            profileName: "alyx", location: location, mode: .auto, artifacts: artifacts,
            replaceCustomFiles: true)
        XCTAssertEqual(result.kind, .alyx)
        XCTAssertEqual(result.targets, [dll.standardizedFileURL])
        guard case .ready(.alyx, _) = result.status else { return XCTFail("\(result.status)") }
        XCTAssertEqual(try Data(contentsOf: dll), try Data(contentsOf: artifacts.proxy))
        XCTAssertEqual(try Data(contentsOf: proxied), try Data(contentsOf: artifacts.openComposite))
        XCTAssertEqual(try Data(contentsOf: backup), valve)
        let iniText = try String(contentsOf: ini)
        XCTAssertTrue(iniText.contains("invertUsingShaders=true"))
        XCTAssertTrue(iniText.contains("initUsingVulkan=false"))
        XCTAssertEqual(try manager.loadProfile("alyx").arguments, ["-novid", "-vr", "-dx11"])

        // Repeat: identical files, the backup still holds Valve's DLL, no extra arguments.
        try manager.prepareVR(profileName: "alyx", location: location, mode: .auto,
                              artifacts: artifacts)
        XCTAssertEqual(try Data(contentsOf: backup), valve)
        XCTAssertEqual(try manager.loadProfile("alyx").arguments, ["-novid", "-vr", "-dx11"])

        // A Steam update puts Valve's DLL back: the status must stop saying ready.
        try valve.write(to: dll)
        guard case .changed(.alyx, let issues) = manager.vrSetupStatus(profileName: "alyx") else {
            return XCTFail("expected changed")
        }
        XCTAssertFalse(issues.isEmpty)
        // Preparing again is allowed (the DLL equals the backup) and keeps the backup.
        try manager.prepareVR(profileName: "alyx", location: location, mode: .auto,
                              artifacts: artifacts)
        XCTAssertEqual(try Data(contentsOf: backup), valve)
        guard case .ready = manager.vrSetupStatus(profileName: "alyx") else {
            return XCTFail("expected ready")
        }

        // Restore puts everything back.
        let report = try manager.restoreVR(profileName: "alyx")
        XCTAssertTrue(report.kept.isEmpty)
        XCTAssertEqual(try Data(contentsOf: dll), valve)
        for removed in [backup, proxied, ini] {
            XCTAssertFalse(fm.fileExists(atPath: removed.path), removed.lastPathComponent)
        }
        XCTAssertEqual(try manager.loadProfile("alyx").arguments,
                       ["-novid", "-g", "D3D11", "-vulkan"])
        XCTAssertEqual(manager.vrSetupStatus(profileName: "alyx"), .notPrepared)
        XCTAssertThrowsError(try manager.restoreVR(profileName: "alyx"))
    }

    func testAlyxArgumentsKeepApplaunchAndOnlyRemoveHelloXRFlags() {
        let change = BottleManager.alyxArguments(
            ["-applaunch", "546560", "-g", "custom", "-ff", "Hmd", "-DX11"])
        XCTAssertEqual(change.arguments, ["-applaunch", "546560", "-g", "custom", "-DX11", "-vr"])
        XCTAssertEqual(change.added, ["-vr"])
        XCTAssertEqual(change.removed, ["-ff", "Hmd"])
    }

    func testMissingArtifactsGiveBuildCommandsAndChangeNothing() throws {
        let (location, dll, valve) = try alyxFixture()
        try fm.removeItem(at: artifacts.proxy)
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "alyx", location: location, mode: .auto, artifacts: artifacts)) {
            XCTAssertTrue($0.localizedDescription.contains("test-openvr-proxy.zsh"))
        }
        try fm.removeItem(at: artifacts.openComposite)
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "alyx", location: location, mode: .auto, artifacts: artifacts)) {
            XCTAssertTrue($0.localizedDescription.contains("build-opencomposite.zsh"))
        }
        XCTAssertEqual(try Data(contentsOf: dll), valve)
        XCTAssertFalse(fm.fileExists(atPath: dll.appendingPathExtension("basalt-original").path))
        XCTAssertEqual(manager.vrSetupStatus(profileName: "alyx"), .notPrepared)
        XCTAssertEqual(try manager.loadProfile("alyx").arguments, ["-novid", "-g", "D3D11", "-vulkan"])
    }

    // MARK: - OpenVR and OpenXR

    func testUncertainGameNeedsAChoiceThenInstallsOpenComposite() throws {
        let exe = try write(Self.pe(marker: 1), "Games/Lab/Lab.exe")
        let dll = try write(Self.pe(marker: 2), "Games/Lab/Sub/openvr_api.dll")
        try saveProfile("lab", executable: #"C:\Games\Lab\Lab.exe"#)
        let location = VRGameLocation(executable: exe, folder: exe.deletingLastPathComponent())

        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "lab", location: location, mode: .auto, artifacts: artifacts))
        XCTAssertEqual(try Data(contentsOf: dll), Self.pe(marker: 2))

        let result = try manager.prepareVR(
            profileName: "lab", location: location, mode: .openVR, artifacts: artifacts,
            replaceCustomFiles: true)
        XCTAssertEqual(result.kind, .openVR)
        XCTAssertEqual(try Data(contentsOf: dll), try Data(contentsOf: artifacts.openComposite))
        XCTAssertEqual(try String(contentsOf: dll.deletingLastPathComponent()
            .appendingPathComponent("opencomposite.ini")), OpenCompositeConfiguration.standard.iniText)
        XCTAssertFalse(fm.fileExists(atPath: dll.deletingLastPathComponent()
            .appendingPathComponent("openvr_api_opencomposite.dll").path))
        XCTAssertEqual(try manager.loadProfile("lab").arguments, [])

        // Switching kinds needs Restore first.
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "lab", location: location, mode: .openXR, artifacts: artifacts))
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "lab", location: location, mode: .alyx, artifacts: artifacts))
    }

    func testNativeOpenXRChangesNoFiles() throws {
        let exe = try write(Self.pe(marker: 1), "Games/XR/XR.exe")
        let loader = try write(Self.pe(marker: 2), "Games/XR/XR_Data/Plugins/x86_64/openxr_loader.dll")
        try saveProfile("xr", executable: #"C:\Games\XR\XR.exe"#)
        let before = try fm.contentsOfDirectory(atPath: exe.deletingLastPathComponent().path).sorted()
        let result = try manager.prepareVR(
            profileName: "xr",
            location: VRGameLocation(executable: exe, folder: exe.deletingLastPathComponent()),
            mode: .auto, artifacts: artifacts)
        XCTAssertEqual(result.kind, .openXR)
        XCTAssertEqual(result.status, .nativeOpenXR)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: exe.deletingLastPathComponent().path).sorted(), before)
        XCTAssertEqual(try Data(contentsOf: loader), Self.pe(marker: 2))
        XCTAssertEqual(manager.vrSetupStatus(profileName: "xr"), .nativeOpenXR)
    }

    func testThirtyTwoBitGameDLLIsRefused() throws {
        let exe = try write(Self.pe(machine: 0x014c, imports: ["openvr_api.dll"], marker: 1),
                            "Games/Old/old.exe")
        let dll = try write(Self.pe(machine: 0x014c, marker: 2), "Games/Old/openvr_api.dll")
        try saveProfile("old", executable: #"C:\Games\Old\old.exe"#)
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "old",
            location: VRGameLocation(executable: exe, folder: exe.deletingLastPathComponent()),
            mode: .auto, artifacts: artifacts)) {
            XCTAssertTrue($0.localizedDescription.contains("32-bit"), $0.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: dll), Self.pe(machine: 0x014c, marker: 2))
    }

    // MARK: - Custom files

    func testCustomConfigurationIsProtectedUntilReplacedAndKeptOnRestore() throws {
        let (location, dll, valve) = try alyxFixture()
        let ini = dll.deletingLastPathComponent().appendingPathComponent("opencomposite.ini")
        let custom = "supersampleRatio=0.7\n"
        try custom.write(to: ini, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "alyx", location: location, mode: .auto, artifacts: artifacts)) {
            XCTAssertEqual(($0 as? VRCustomFilesError)?.files,
                           [dll.standardizedFileURL, ini.standardizedFileURL])
        }
        XCTAssertEqual(try Data(contentsOf: dll), valve)
        XCTAssertEqual(try String(contentsOf: ini), custom)
        XCTAssertFalse(fm.fileExists(atPath: dll.appendingPathExtension("basalt-original").path))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try manager.prepareVR(
            profileName: "alyx", location: location, mode: .auto, artifacts: artifacts,
            replaceCustomFiles: true, now: now)
        XCTAssertEqual(result.replacedCopies.count, 2)
        let copy = try XCTUnwrap(result.replacedCopies.first { $0.lastPathComponent.hasPrefix("opencomposite.ini") })
        XCTAssertEqual(try String(contentsOf: copy), custom)
        XCTAssertTrue(try String(contentsOf: ini).contains("invertUsingShaders=true"))

        try manager.restoreVR(profileName: "alyx")
        XCTAssertEqual(try Data(contentsOf: dll), valve)
        XCTAssertEqual(try String(contentsOf: copy), custom)
    }

    func testUnknownDLLWithAnExistingBackupIsNotOverwritten() throws {
        let (location, dll, valve) = try alyxFixture()
        let backup = dll.appendingPathExtension("basalt-original")
        try valve.write(to: backup)
        let customOpenComposite = Self.pe(marker: 0x77)
        try customOpenComposite.write(to: dll)
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "alyx", location: location, mode: .auto, artifacts: artifacts)) {
            XCTAssertEqual(($0 as? VRCustomFilesError)?.files, [dll.standardizedFileURL])
        }
        XCTAssertEqual(try Data(contentsOf: dll), customOpenComposite)

        try manager.prepareVR(profileName: "alyx", location: location, mode: .auto,
                              artifacts: artifacts, replaceCustomFiles: true)
        XCTAssertEqual(try Data(contentsOf: backup), valve, "the original backup is never replaced")
    }

    func testRestoreLeavesFilesThatChangedAfterSetup() throws {
        let (location, dll, valve) = try alyxFixture()
        try manager.prepareVR(profileName: "alyx", location: location, mode: .auto,
                              artifacts: artifacts, replaceCustomFiles: true)
        let ini = dll.deletingLastPathComponent().appendingPathComponent("opencomposite.ini")
        try "supersampleRatio=0.5\n".write(to: ini, atomically: true, encoding: .utf8)
        let report = try manager.restoreVR(profileName: "alyx")
        XCTAssertEqual(report.kept, [ini])
        XCTAssertEqual(try String(contentsOf: ini), "supersampleRatio=0.5\n")
        XCTAssertEqual(try Data(contentsOf: dll), valve)
    }

    // MARK: - Boundaries and failures

    func testPathsOutsideTheBottleAndSymbolicLinksAreRefused() throws {
        let (location, dll, valve) = try alyxFixture()
        try saveProfile("other", executable: #"C:\Games\x.exe"#)

        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "other", location: VRGameLocation(executable: nil, folder: outside),
            mode: .openVR, artifacts: artifacts))
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "other",
            location: VRGameLocation(executable: nil,
                                     folder: driveC.appendingPathComponent("../../outside")),
            mode: .openVR, artifacts: artifacts))
        XCTAssertNil(BottleManager.hostURL(forWindowsPath: #"C:\Games\..\..\x.exe"#, prefix: prefix))
        XCTAssertNil(BottleManager.hostURL(forWindowsPath: #"Z:\tmp\x.exe"#, prefix: prefix))

        // A game folder that is a link to outside the bottle.
        try Self.pe(marker: 1).write(to: outside.appendingPathComponent("hlvr.exe"))
        try fm.createSymbolicLink(at: driveC.appendingPathComponent("Linked"),
                                  withDestinationURL: outside)
        let linked = driveC.appendingPathComponent("Linked")
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "other",
            location: VRGameLocation(executable: linked.appendingPathComponent("hlvr.exe"),
                                     folder: linked),
            mode: .alyx, artifacts: artifacts))
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("openvr_api.dll").path))

        // The game DLL itself is a symbolic link, even to a file inside the bottle.
        let elsewhere = try write(valve, "Shared/valve.dll")
        try fm.removeItem(at: dll)
        try fm.createSymbolicLink(at: dll, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "alyx", location: location, mode: .auto, artifacts: artifacts))
        XCTAssertEqual(try Data(contentsOf: elsewhere), valve)
    }

    func testFailureHalfwayRollsBackEveryFile() throws {
        let exe = try write(Self.pe(marker: 1), "Games/Two/Two.exe")
        let first = try write(Self.pe(marker: 2), "Games/Two/a/openvr_api.dll")
        let second = try write(Self.pe(marker: 3), "Games/Two/b/openvr_api.dll")
        try saveProfile("two", executable: #"C:\Games\Two\Two.exe"#)
        // The second folder cannot be written.
        try fm.setAttributes([.posixPermissions: 0o555],
                             ofItemAtPath: second.deletingLastPathComponent().path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: second.deletingLastPathComponent().path)
        }
        XCTAssertThrowsError(try manager.prepareVR(
            profileName: "two",
            location: VRGameLocation(executable: exe, folder: exe.deletingLastPathComponent()),
            mode: .openVR, artifacts: artifacts, replaceCustomFiles: true)) {
            XCTAssertFalse($0 is VRCustomFilesError, "\($0)")
        }
        XCTAssertEqual(try Data(contentsOf: first), Self.pe(marker: 2))
        XCTAssertEqual(try Data(contentsOf: second), Self.pe(marker: 3))
        let firstDirectory = try fm.contentsOfDirectory(atPath: first.deletingLastPathComponent().path)
        XCTAssertEqual(firstDirectory, ["openvr_api.dll"])
        XCTAssertEqual(manager.vrSetupStatus(profileName: "two"), .notPrepared)
    }

    func testSteamApplaunchProfileFindsAlyxInTheInstallFolder() throws {
        let (_, _, _) = try alyxFixture()
        try manager.saveProfile(LaunchProfile(
            name: "alyx-steam", bottleName: "Test", source: .steam,
            executable: #"C:\Program Files (x86)\Steam\steam.exe"#,
            arguments: ["-applaunch", "546560"]))
        let profile = try manager.loadProfile("alyx-steam")
        XCTAssertThrowsError(try manager.vrGameLocation(for: profile))
        let install = driveC.appendingPathComponent(
            "Program Files (x86)/Steam/steamapps/common/Half-Life Alyx")
        let location = try manager.vrGameLocation(for: profile, steamInstallDirectory: install)
        XCTAssertEqual(location.executable?.lastPathComponent, "hlvr.exe")
        XCTAssertEqual(location.steamAppID, "546560")
    }

    func testManualInstallerRefusesACustomConfiguration() throws {
        let (_, dll, _) = try alyxFixture()
        let ini = dll.deletingLastPathComponent().appendingPathComponent("opencomposite.ini")
        try "handColour=#ff0000\n".write(to: ini, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try manager.installOpenComposite(
            profileName: "alyx", artifact: artifacts.openComposite, targetDLL: dll))
        XCTAssertEqual(try String(contentsOf: ini), "handColour=#ff0000\n")
    }

    // MARK: - Review fixes

    func testUnknownGameDLLWithoutBackupStaysUntilReplaceIsConfirmed() throws {
        let exe = try write(Self.pe(imports: ["openvr_api.dll"], marker: 1), "Games/Own/Own.exe")
        let foreign = Self.pe(marker: 0x99) // someone's own OpenComposite build
        let dll = try write(foreign, "Games/Own/openvr_api.dll")
        let backup = dll.appendingPathExtension("basalt-original")
        try saveProfile("own", executable: #"C:\Games\Own\Own.exe"#)
        let location = VRGameLocation(executable: exe, folder: exe.deletingLastPathComponent())

        for _ in 0..<2 {
            XCTAssertThrowsError(try manager.prepareVR(
                profileName: "own", location: location, mode: .auto, artifacts: artifacts)) {
                XCTAssertEqual(($0 as? VRCustomFilesError)?.files, [dll.standardizedFileURL])
            }
            XCTAssertEqual(try Data(contentsOf: dll), foreign)
            XCTAssertFalse(fm.fileExists(atPath: backup.path))
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: exe.deletingLastPathComponent().path).sorted(),
                           ["Own.exe", "openvr_api.dll"])
            XCTAssertEqual(manager.vrSetupStatus(profileName: "own"), .notPrepared)
        }

        let result = try manager.prepareVR(
            profileName: "own", location: location, mode: .auto, artifacts: artifacts,
            replaceCustomFiles: true)
        XCTAssertEqual(try Data(contentsOf: backup), foreign)
        XCTAssertEqual(result.replacedCopies.count, 1)
        XCTAssertEqual(try Data(contentsOf: result.replacedCopies[0]), foreign)
        XCTAssertEqual(try Data(contentsOf: dll), try Data(contentsOf: artifacts.openComposite))

        // Preparing again needs no permission and keeps the backup.
        try manager.prepareVR(profileName: "own", location: location, mode: .auto,
                              artifacts: artifacts)
        XCTAssertEqual(try Data(contentsOf: backup), foreign)

        try manager.restoreVR(profileName: "own")
        XCTAssertEqual(try Data(contentsOf: dll), foreign)
        XCTAssertEqual(try Data(contentsOf: result.replacedCopies[0]), foreign)
    }

    func testReplacedCopiesAtTheSameTimeNeverOverwriteEachOther() throws {
        let (location, dll, _) = try alyxFixture()
        let directory = dll.deletingLastPathComponent()
        let ini = directory.appendingPathComponent("opencomposite.ini")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = BottleManager.timestamp(now)
        // Collisions at the first names: a link and a folder must be left alone.
        let elsewhere = try write(Data("elsewhere".utf8), "Shared/elsewhere.txt")
        try fm.createSymbolicLink(
            at: directory.appendingPathComponent("opencomposite.ini.basalt-replaced-\(stamp)"),
            withDestinationURL: elsewhere)
        try fm.createDirectory(
            at: directory.appendingPathComponent("opencomposite.ini.basalt-replaced-\(stamp)-2"),
            withIntermediateDirectories: true)

        try manager.prepareVR(profileName: "alyx", location: location, mode: .auto,
                              artifacts: artifacts, replaceCustomFiles: true, now: now)
        var copies = [URL]()
        for text in ["first=1\n", "second=2\n"] {
            try text.write(to: ini, atomically: true, encoding: .utf8)
            let result = try manager.prepareVR(
                profileName: "alyx", location: location, mode: .auto, artifacts: artifacts,
                replaceCustomFiles: true, now: now)
            XCTAssertEqual(result.replacedCopies.count, 1)
            copies += result.replacedCopies
        }
        XCTAssertEqual(Set(copies).count, 2)
        XCTAssertEqual(try String(contentsOf: copies[0]), "first=1\n")
        XCTAssertEqual(try String(contentsOf: copies[1]), "second=2\n")
        XCTAssertEqual(try String(contentsOf: elsewhere), "elsewhere")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(
            atPath: directory.appendingPathComponent("opencomposite.ini.basalt-replaced-\(stamp)-2").path,
            isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    func testAlyxArgumentsRemoveHelloXRSpaceOnlyWithKnownNames() {
        let change = BottleManager.alyxArguments(["--graphics", "D3D11", "--space", "Local"])
        XCTAssertEqual(change.arguments, ["-vr", "-dx11"])
        XCTAssertEqual(change.removed, ["--graphics", "D3D11", "--space", "Local"])

        let other = BottleManager.alyxArguments(["-s", "Custom", "-S", "stage", "--space"])
        XCTAssertEqual(other.arguments, ["-s", "Custom", "--space", "-vr", "-dx11"])
        XCTAssertEqual(other.removed, ["-S", "stage"])
    }

    func testRestorePutsBackTheExactArgumentOrder() throws {
        let (location, _, _) = try alyxFixture()
        let original = ["-novid", "--graphics", "D3D11", "--space", "Local", "-console"]
        var profile = try manager.loadProfile("alyx")
        profile.arguments = original
        try manager.saveProfile(profile)
        try manager.prepareVR(profileName: "alyx", location: location, mode: .auto,
                              artifacts: artifacts, replaceCustomFiles: true)
        XCTAssertEqual(try manager.loadProfile("alyx").arguments, ["-novid", "-console", "-vr", "-dx11"])
        try manager.prepareVR(profileName: "alyx", location: location, mode: .auto,
                              artifacts: artifacts)
        try manager.restoreVR(profileName: "alyx")
        XCTAssertEqual(try manager.loadProfile("alyx").arguments, original)

        // After the user edits the arguments, Restore keeps the edit and every pair together.
        // Restore removed the backup, so the game's DLL needs permission again.
        try manager.prepareVR(profileName: "alyx", location: location, mode: .auto,
                              artifacts: artifacts, replaceCustomFiles: true)
        profile = try manager.loadProfile("alyx")
        profile.arguments.append("-high")
        try manager.saveProfile(profile)
        try manager.restoreVR(profileName: "alyx")
        let restored = try manager.loadProfile("alyx").arguments
        XCTAssertEqual(restored, ["-novid", "-console", "-high", "--graphics", "D3D11", "--space", "Local"])
    }

    func testRestoreWithoutTheOriginalKeepsACoherentSetupAndTheRecord() throws {
        let (location, dll, valve) = try alyxFixture()
        let directory = dll.deletingLastPathComponent()
        let backup = dll.appendingPathExtension("basalt-original")
        let proxied = directory.appendingPathComponent("openvr_api_opencomposite.dll")
        let ini = directory.appendingPathComponent("opencomposite.ini")
        try manager.prepareVR(profileName: "alyx", location: location, mode: .auto,
                              artifacts: artifacts, replaceCustomFiles: true)
        try fm.removeItem(at: backup)

        let report = try manager.restoreVR(profileName: "alyx")
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.unrestored, [dll.standardizedFileURL])
        XCTAssertFalse(report.restored.contains(dll.standardizedFileURL))
        XCTAssertEqual(Set(report.kept), Set([dll, proxied, ini].map(\.standardizedFileURL)))
        XCTAssertEqual(try Data(contentsOf: dll), try Data(contentsOf: artifacts.proxy))
        XCTAssertEqual(try Data(contentsOf: proxied), try Data(contentsOf: artifacts.openComposite))
        XCTAssertTrue(fm.fileExists(atPath: ini.path))
        XCTAssertEqual(try manager.loadProfile("alyx").arguments, ["-novid", "-vr", "-dx11"])
        guard case .ready = manager.vrSetupStatus(profileName: "alyx") else {
            return XCTFail("the setup must stay recorded")
        }

        // With the original back, Restore can finish.
        try valve.write(to: backup)
        let retry = try manager.restoreVR(profileName: "alyx")
        XCTAssertTrue(retry.isComplete)
        XCTAssertEqual(try Data(contentsOf: dll), valve)
        XCTAssertEqual(try manager.loadProfile("alyx").arguments, ["-novid", "-g", "D3D11", "-vulkan"])
        XCTAssertEqual(manager.vrSetupStatus(profileName: "alyx"), .notPrepared)
    }
}
