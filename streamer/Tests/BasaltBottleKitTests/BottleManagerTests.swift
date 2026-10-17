import XCTest
@testable import BasaltBottleKit

final class BottleManagerTests: XCTestCase {
    func testProcessRunnerDoesNotWaitForBackgroundDescendantsHoldingOutput() throws {
        let runner = ProcessBottleCommandRunner()
        let started = Date()
        let result = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(sleep 3) & printf ready"],
            environment: [:], currentDirectory: nil)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "ready")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testBottleProcessCleanupUsesPrefixScopedWineserver() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltWineCleanup-\(UUID().uuidString)", isDirectory: true)
        let bin = temporary.appendingPathComponent("engine/bin", isDirectory: true)
        let wine = bin.appendingPathComponent("wine")
        let wineserver = bin.appendingPathComponent("wineserver")
        let prefix = temporary.appendingPathComponent("prefix", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: prefix, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
        try Data("#!/bin/sh\nprintf '%s|%s|%s' \"$WINEPREFIX\" \"$1\" \"$2\"\n".utf8)
            .write(to: wineserver)
        for executable in [wine, wineserver] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let manager = BottleManager(
            root: temporary.appendingPathComponent("data"),
            repoRoot: temporary)
        let command = BottleLaunchCommand(
            executable: wine,
            arguments: [#"C:\Games\Game.exe"#],
            environment: ["WINEPREFIX": prefix.path],
            currentDirectory: nil)

        let result = try manager.terminateBottleProcesses(launchedWith: command)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "\(prefix.path)|--kill|--wait")

        try manager.prepare()
        let bottleDirectory = try manager.paths.bottleDirectory("Test")
        let managedPrefix = bottleDirectory.appendingPathComponent(
            "prefix", isDirectory: true)
        let managedEngine = bottleDirectory.appendingPathComponent(
            "engine", isDirectory: true)
        let managedBin = managedEngine.appendingPathComponent(
            "bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: managedPrefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: managedBin, withIntermediateDirectories: true)
        let managedWine = managedBin.appendingPathComponent("wine")
        let managedWineserver = managedBin.appendingPathComponent("wineserver")
        try FileManager.default.copyItem(at: wine, to: managedWine)
        try FileManager.default.copyItem(at: wineserver, to: managedWineserver)
        let engine = BottleEngine(
            id: "test", kind: .pinned,
            wineBinary: managedWine, wineserverBinary: managedWineserver,
            root: managedEngine,
            supportsBasaltDXMT: true)
        let bottle = ManagedBottle(
            name: "Test", engine: engine, prefix: managedPrefix,
            engineRoot: managedEngine,
            wineBinary: managedWine)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(
            to: bottleDirectory.appendingPathComponent("bottle.json"))
        try manager.saveProfile(LaunchProfile(
            name: "game", bottleName: "Test", source: .direct,
            executable: #"C:\Games\Game.exe"#))

        let profileResult = try manager.terminateBottleProcesses(
            forProfile: "game")

        XCTAssertEqual(profileResult.status, 0)
        XCTAssertEqual(profileResult.output, "\(managedPrefix.path)|--kill|--wait")

        // Wine reports "no server for this prefix" as status 1 with no
        // diagnostic. Cleanup is already complete in that case.
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: wineserver)
        let inactiveResult = try manager.terminateBottleProcesses(
            launchedWith: command)
        XCTAssertEqual(inactiveResult, CommandOutput(status: 0, output: ""))

        try Data("#!/bin/sh\nprintf 'permission denied\\n' >&2\nexit 1\n".utf8)
            .write(to: wineserver)
        XCTAssertThrowsError(try manager.terminateBottleProcesses(
            launchedWith: command)) { error in
            XCTAssertEqual(
                error as? BottleToolError,
                BottleToolError(
                    "Could not stop Wine processes for \(prefix.path): permission denied"))
        }
    }

    func testBottleNamesRejectTraversalAndWhitespace() throws {
        XCTAssertEqual(try BottleName.validate("beat-saber_1.2"), "beat-saber_1.2")
        for invalid in ["", "../Steam", "two words", "/absolute", ".hidden", "a/b"] {
            XCTAssertThrowsError(try BottleName.validate(invalid))
        }
    }

    func testManagedPathsStayUnderRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/Basalt Managed", isDirectory: true)
        let paths = BasaltManagedPaths(root: root)
        let bottle = try paths.bottleDirectory("BeatSaber")
        XCTAssertTrue(paths.contains(bottle))
        XCTAssertFalse(paths.contains(URL(fileURLWithPath: "/tmp/Basalt Managed Elsewhere/x")))
        XCTAssertThrowsError(try paths.bottleDirectory("../escape"))
    }

    func testPrepareRejectsManagedDirectorySymlinkEscape() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltBottleRoot-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Bottles"),
            withDestinationURL: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let manager = BottleManager(root: root, repoRoot: temporary)
        XCTAssertThrowsError(try manager.prepare())
    }

    func testWinePathMapsPrefixAndExternalPaths() {
        let prefix = URL(fileURLWithPath: "/tmp/Basalt/Bottles/Test/prefix")
        XCTAssertEqual(
            BottleManager.winePath(
                for: prefix.appendingPathComponent("drive_c/Games/Test/game.exe"),
                prefix: prefix),
            #"C:\Games\Test\game.exe"#)
        XCTAssertEqual(
            BottleManager.winePath(
                for: URL(fileURLWithPath: "/tmp/runtime-control"), prefix: prefix),
            #"Z:\tmp\runtime-control"#)
    }

    func testBottleAndProfileRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let engine = BottleEngine(
            id: "test", kind: .pinned,
            wineBinary: URL(fileURLWithPath: "/engine/bin/wine"),
            wineserverBinary: URL(fileURLWithPath: "/engine/bin/wineserver"),
            root: URL(fileURLWithPath: "/engine"), supportsBasaltDXMT: true)
        let bottle = ManagedBottle(
            name: "test", engine: engine,
            prefix: URL(fileURLWithPath: "/data/prefix"),
            engineRoot: URL(fileURLWithPath: "/data/engine"),
            wineBinary: URL(fileURLWithPath: "/data/engine/bin/wine"),
            createdAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(try decoder.decode(
            ManagedBottle.self, from: encoder.encode(bottle)), bottle)

        let profile = LaunchProfile(
            name: "beat-saber", bottleName: "test", source: .steam,
            executable: #"C:\Games\Beat Saber\Beat Saber.exe"#,
            arguments: ["--verbose"], workingDirectory: "/data/prefix/drive_c/Games",
            environment: ["KEY": "VALUE"])
        XCTAssertEqual(try decoder.decode(
            LaunchProfile.self, from: encoder.encode(profile)), profile)

        // gameRoot is optional: profiles saved before it existed still load.
        let legacy = Data("""
            {"formatVersion":1,"name":"lab","bottleName":"test","source":"steam",\
            "executable":"C:\\\\Lab.exe","arguments":[],"environment":{}}
            """.utf8)
        XCTAssertNil(try decoder.decode(LaunchProfile.self, from: legacy).gameRoot)
        var rooted = profile
        rooted.gameRoot = #"C:\Program Files (x86)\Steam\steamapps\common\The Lab"#
        XCTAssertEqual(try decoder.decode(
            LaunchProfile.self, from: encoder.encode(rooted)).gameRoot, rooted.gameRoot)
    }

    func testProfileAndOpenCompositeInstallStayInsideManagedPrefix() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltBottleKit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let repo = temporary.appendingPathComponent("repo", isDirectory: true)
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Test", isDirectory: true)
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: engineRoot.appendingPathComponent("bin"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: prefix, withIntermediateDirectories: true)

        let engine = BottleEngine(
            id: "test-pinned", kind: .pinned,
            wineBinary: engineRoot.appendingPathComponent("bin/wine"),
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        let bottle = ManagedBottle(
            name: "Test", engine: engine, prefix: prefix,
            engineRoot: engineRoot,
            wineBinary: engineRoot.appendingPathComponent("bin/wine"))
        let metadataEncoder = JSONEncoder()
        metadataEncoder.dateEncodingStrategy = .iso8601
        try metadataEncoder.encode(bottle).write(
            to: directory.appendingPathComponent("bottle.json"))

        let manager = BottleManager(root: root, repoRoot: repo)
        let profile = LaunchProfile(
            name: "beat-saber", bottleName: "Test", source: .steam,
            executable: #"C:\Games\Beat Saber\Beat Saber.exe"#)
        try manager.saveProfile(profile)
        XCTAssertEqual(try manager.loadProfile("beat-saber"), profile)

        let artifact = temporary.appendingPathComponent("openvr_api.dll")
        try Data([0x4d, 0x5a, 0x01, 0x02]).write(to: artifact)
        let target = prefix.appendingPathComponent(
            "drive_c/Games/Beat Saber/Beat Saber_Data/Plugins/x86_64/openvr_api.dll")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data([0x4d, 0x5a, 0xaa])
        try original.write(to: target)

        XCTAssertEqual(
            try manager.installOpenComposite(
                profileName: profile.name, artifact: artifact, targetDLL: target),
            target.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: target), Data([0x4d, 0x5a, 0x01, 0x02]))
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathExtension("basalt-original")),
            original)
        let configuration = try String(contentsOf:
            target.deletingLastPathComponent().appendingPathComponent("opencomposite.ini"))
        XCTAssertTrue(configuration.contains("initUsingVulkan=false"))
        // The openxr branch of OpenComposite aborts on unknown options such as enableAudio.
        XCTAssertFalse(configuration.contains("enableAudio"))
        XCTAssertFalse(configuration.contains("invertUsingShaders"))

        let escaped = temporary.appendingPathComponent("openvr_api.dll")
        XCTAssertThrowsError(try manager.installOpenComposite(
            profileName: profile.name, artifact: artifact, targetDLL: escaped))

        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: true)
        let redirect = prefix.appendingPathComponent("drive_c/redirect", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: redirect, withDestinationURL: outside)
        XCTAssertThrowsError(try manager.installOpenComposite(
            profileName: profile.name, artifact: artifact,
            targetDLL: redirect.appendingPathComponent("openvr_api.dll")))
    }

    func testOpenCompositeConfigurationPresetsMatchOpenCompositeParser() throws {
        XCTAssertEqual(OpenCompositeConfiguration.standard.iniText, """
            ; Managed by BasaltVR. OpenComposite remains a separately built GPLv3 artifact.
            initUsingVulkan=false

            """)
        XCTAssertEqual(OpenCompositeConfiguration.alyx.iniText, """
            ; Managed by BasaltVR. OpenComposite remains a separately built GPLv3 artifact.
            initUsingVulkan=false
            invertUsingShaders=true

            """)

        var configuration = OpenCompositeConfiguration(preset: .alyx)
        try configuration.apply("supersampleRatio=1.25")
        try configuration.apply("invertUsingShaders=off")
        try configuration.set("handColour", to: "#FF8800")
        XCTAssertEqual(configuration.options.map(\.key), [
            "initUsingVulkan", "invertUsingShaders", "supersampleRatio", "handColour",
        ])
        XCTAssertEqual(configuration.value(for: "invertUsingShaders"), "off")
        XCTAssertTrue(configuration.iniText.contains("\nsupersampleRatio=1.25\n"))

        for invalid in [
            "enableAudio=false", "invertUsingShaders=yes", "supersampleRatio=fast",
            "supersampleRatio=1.0\ninitUsingVulkan=true", "supersampleRatio=inf",
            "handColour=#ff88", "handColour=orange", "initUsingVulkan", "=true",
            "InitUsingVulkan=false",
        ] {
            XCTAssertThrowsError(try configuration.apply(invalid), invalid)
        }
        XCTAssertEqual(OpenCompositeConfiguration.Preset(rawValue: "default"), .standard)
        XCTAssertEqual(OpenCompositeConfiguration.Preset(rawValue: "alyx"), .alyx)
    }

    func testOpenCompositeProxyInstallPlacesBothDLLsAndPresetConfiguration() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltOpenVRProxy-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Test", isDirectory: true)
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: engineRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let engine = BottleEngine(
            id: "test-pinned", kind: .pinned,
            wineBinary: engineRoot.appendingPathComponent("bin/wine"),
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        let bottle = ManagedBottle(
            name: "Test", engine: engine, prefix: prefix, engineRoot: engineRoot,
            wineBinary: engineRoot.appendingPathComponent("bin/wine"))
        let metadataEncoder = JSONEncoder()
        metadataEncoder.dateEncodingStrategy = .iso8601
        try metadataEncoder.encode(bottle).write(
            to: directory.appendingPathComponent("bottle.json"))
        let manager = BottleManager(
            root: root, repoRoot: temporary.appendingPathComponent("repo"))
        try manager.saveProfile(LaunchProfile(
            name: "alyx", bottleName: "Test", source: .steam,
            executable: #"C:\Games\Half-Life Alyx\game\bin\win64\hlvr.exe"#))

        func peImage(machine: UInt16, marker: UInt8) -> Data {
            var image = [UInt8](repeating: 0, count: 0x48)
            image[0] = 0x4d
            image[1] = 0x5a
            image[0x3c] = 0x40
            image[0x40] = 0x50
            image[0x41] = 0x45
            image[0x44] = UInt8(machine & 0xff)
            image[0x45] = UInt8(machine >> 8)
            image[0x47] = marker
            return Data(image)
        }
        let openComposite = temporary.appendingPathComponent("openvr_api_opencomposite.dll")
        let proxy = temporary.appendingPathComponent("proxy-openvr_api.dll")
        let proxy32 = temporary.appendingPathComponent("proxy32-openvr_api.dll")
        let notPE = temporary.appendingPathComponent("not-pe.dll")
        try peImage(machine: 0x8664, marker: 1).write(to: openComposite)
        try peImage(machine: 0x8664, marker: 2).write(to: proxy)
        try peImage(machine: 0x014c, marker: 3).write(to: proxy32)
        try Data([0x4d, 0x5a, 0x01]).write(to: notPE)
        XCTAssertEqual(BottleManager.peMachine(try Data(contentsOf: proxy)), 0x8664)
        XCTAssertNil(BottleManager.peMachine(try Data(contentsOf: notPE)))

        let binDirectory = prefix.appendingPathComponent(
            "drive_c/Games/Half-Life Alyx/game/bin/win64", isDirectory: true)
        let target = binDirectory.appendingPathComponent("openvr_api.dll")
        let proxied = binDirectory.appendingPathComponent("openvr_api_opencomposite.dll")
        let ini = binDirectory.appendingPathComponent("opencomposite.ini")
        try FileManager.default.createDirectory(
            at: binDirectory, withIntermediateDirectories: true)
        let valveOriginal = Data([0x4d, 0x5a, 0x56])
        try valveOriginal.write(to: target)

        XCTAssertThrowsError(try manager.installOpenComposite(
            profileName: "alyx", artifact: openComposite, targetDLL: target,
            proxy: proxy32, configuration: .alyx))
        XCTAssertThrowsError(try manager.installOpenComposite(
            profileName: "alyx", artifact: openComposite, targetDLL: target,
            proxy: notPE, configuration: .alyx))
        XCTAssertThrowsError(try manager.installOpenComposite(
            profileName: "alyx", artifact: notPE, targetDLL: target,
            proxy: proxy, configuration: .alyx))
        XCTAssertEqual(try Data(contentsOf: target), valveOriginal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxied.path))

        XCTAssertEqual(try manager.installOpenComposite(
            profileName: "alyx", artifact: openComposite, targetDLL: target,
            proxy: proxy, configuration: .alyx), target.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: proxy))
        XCTAssertEqual(try Data(contentsOf: proxied), try Data(contentsOf: openComposite))
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathExtension("basalt-original")),
            valveOriginal)
        XCTAssertEqual(try String(contentsOf: ini), OpenCompositeConfiguration.alyx.iniText)

        // Reinstalling keeps Valve's DLL as the backup, not the proxy.
        _ = try manager.installOpenComposite(
            profileName: "alyx", artifact: openComposite, targetDLL: target,
            proxy: proxy, configuration: .alyx)
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathExtension("basalt-original")),
            valveOriginal)

        // A plain install replaces the proxy and removes the forwarded copy.
        _ = try manager.installOpenComposite(
            profileName: "alyx", artifact: openComposite, targetDLL: target)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: openComposite))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxied.path))
        XCTAssertEqual(try String(contentsOf: ini), OpenCompositeConfiguration.standard.iniText)
    }

    func testProfileLaunchCommandIsValidatedAndResolvedForGUIOwnership() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltLaunchCommand-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Test", isDirectory: true)
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        let wine = engineRoot.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wine.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let engine = BottleEngine(
            id: "test-pinned", kind: .pinned, wineBinary: wine,
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        var bottle = ManagedBottle(
            name: "Test", engine: engine, prefix: prefix,
            engineRoot: engineRoot, wineBinary: wine)
        bottle.dxmtInstalled = true
        bottle.runtimeInstalled = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))

        let manager = BottleManager(root: root, repoRoot: temporary)
        try manager.saveProfile(LaunchProfile(
            name: "game", bottleName: "Test", source: .direct,
            executable: #"C:\Games\Game.exe"#, arguments: ["-vr"],
            environment: ["GAME_MODE": "test"]))
        let control = temporary.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)

        let command = try manager.profileLaunchCommand(
            "game", controlFile: control, additionalArguments: ["-debug"])

        XCTAssertEqual(command.executable, wine.standardizedFileURL)
        XCTAssertEqual(
            command.arguments,
            [#"C:\Games\Game.exe"#, "-vr", "-debug"])
        XCTAssertEqual(command.environment["WINEPREFIX"], prefix.path)
        XCTAssertEqual(command.environment["WINEARCH"], "win64")
        XCTAssertEqual(command.environment["MVK_CONFIG_LOG_LEVEL"], "0")
        XCTAssertEqual(command.environment["DXMT_BASALT_IOSURFACE"], "1")
        XCTAssertEqual(command.environment["GAME_MODE"], "test")
        XCTAssertEqual(
            command.environment["BASALT_CONTROL"],
            "Z:" + control.path.replacingOccurrences(of: "/", with: #"\"#))
    }

    func testLegacySteamBeatSaberProfileResolvesToWaitedGameProcess() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltSteamLaunch-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Steam", isDirectory: true)
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        let wine = engineRoot.appendingPathComponent("bin/wine")
        let beatSaber = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steamapps/common/Beat Saber/Beat Saber.exe")
        let steam = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steam.exe")
        let webHelper = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe")
        let compatibilityArtifact = temporary.appendingPathComponent(
            "runtime/build/bin/steamwebhelper_compat.exe")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: beatSaber.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: webHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: compatibilityArtifact.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try Data([0x4d, 0x5a]).write(to: beatSaber)
        try Data([0x4d, 0x5a]).write(to: steam)
        let originalHelper = Data([0x4d, 0x5a, 0x10])
        func shimBytes(_ build: UInt8) -> Data {
            var data = Data([0x4d, 0x5a, build])
            for unit in "steamwebhelper.basalt-original.exe".utf16 {
                data.append(UInt8(unit & 0xff))
                data.append(UInt8(unit >> 8))
            }
            return data
        }
        let compatibilityShim = shimBytes(0x20)
        try originalHelper.write(to: webHelper)
        try compatibilityShim.write(to: compatibilityArtifact)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wine.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let engine = BottleEngine(
            id: "test-pinned", kind: .pinned, wineBinary: wine,
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        var bottle = ManagedBottle(
            name: "Steam", engine: engine, prefix: prefix,
            engineRoot: engineRoot, wineBinary: wine)
        bottle.dxmtInstalled = true
        bottle.runtimeInstalled = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))

        let manager = BottleManager(root: root, repoRoot: temporary)
        try manager.saveProfile(LaunchProfile(
            name: "beat-saber", bottleName: "Steam", source: .steam,
            executable: #"C:\Program Files (x86)\Steam\steam.exe"#,
            arguments: ["-applaunch", "620980", "-vrmode", "openxr"]))
        let control = temporary.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)

        let command = try manager.profileLaunchCommand("beat-saber", controlFile: control)

        XCTAssertEqual(command.arguments, [
            #"C:\Program Files (x86)\Steam\steamapps\common\Beat Saber\Beat Saber.exe"#,
            "-vrmode", "openxr",
        ])
        XCTAssertEqual(command.currentDirectory, beatSaber.deletingLastPathComponent())
        XCTAssertEqual(command.environment["SteamAppId"], "620980")
        XCTAssertEqual(command.environment["SteamGameId"], "620980")

        XCTAssertEqual(
            try manager.installSteamWebHelperCompatibility(forProfile: "beat-saber"),
            webHelper)
        XCTAssertEqual(try Data(contentsOf: webHelper), compatibilityShim)
        let preservedHelper = webHelper.deletingPathExtension()
            .appendingPathExtension("basalt-original.exe")
        XCTAssertEqual(try Data(contentsOf: preservedHelper), originalHelper)

        // An external Steam update replaces the shim. Basalt must retain the
        // new matching original instead of launching the stale preserved copy.
        let updatedHelper = Data([0x4d, 0x5a, 0x30])
        try updatedHelper.write(to: webHelper)
        _ = try manager.installSteamWebHelperCompatibility(forProfile: "beat-saber")
        XCTAssertEqual(try Data(contentsOf: webHelper), compatibilityShim)
        XCTAssertEqual(try Data(contentsOf: preservedHelper), updatedHelper)

        // A shim from another Basalt build (another checkout or worktree) is
        // installed. It must be replaced, never preserved as the original:
        // a preserved shim launches itself without end (a process storm).
        let otherBuildShim = shimBytes(0x21)
        try otherBuildShim.write(to: webHelper)
        _ = try manager.installSteamWebHelperCompatibility(forProfile: "beat-saber")
        XCTAssertEqual(try Data(contentsOf: webHelper), compatibilityShim)
        XCTAssertEqual(try Data(contentsOf: preservedHelper), updatedHelper)

        // A preserved "original" that is a shim (left by an older Basalt) is
        // refused, and the installed helper is not touched.
        try otherBuildShim.write(to: preservedHelper)
        XCTAssertThrowsError(
            try manager.installSteamWebHelperCompatibility(forProfile: "beat-saber"))
        XCTAssertEqual(try Data(contentsOf: webHelper), compatibilityShim)
        try updatedHelper.write(to: preservedHelper)

        let bootstrap = try XCTUnwrap(
            manager.steamBootstrapCommand(forProfile: "beat-saber"))
        XCTAssertEqual(bootstrap.executable, wine.standardizedFileURL)
        XCTAssertEqual(bootstrap.arguments, [
            #"C:\Program Files (x86)\Steam\steam.exe"#,
            "-inhibitbootstrap", "-noverifyfiles", "-no-cef-sandbox",
        ])
        XCTAssertEqual(bootstrap.currentDirectory, prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam"))
        XCTAssertEqual(bootstrap.environment["MVK_CONFIG_LOG_LEVEL"], "0")
        XCTAssertEqual(
            try manager.steamConnectionLogURL(forProfile: "beat-saber"),
            prefix.appendingPathComponent(
                "drive_c/Program Files (x86)/Steam/logs/connection_log.txt"))

        // BSManager instances are launched directly from their external
        // BSInstances directory, but still require the managed bottle's Steam
        // client to be signed in before SteamAPI initializes.
        try manager.saveProfile(LaunchProfile(
            name: "bsmanager-instance", bottleName: "Steam", source: .bsmanager,
            executable: #"Z:\Users\player\BSManager\BSInstances\1.40.8\Beat Saber.exe"#,
            environment: ["WINEDLLOVERRIDES": "winhttp=n,b"]))
        XCTAssertNotNil(try manager.installSteamWebHelperCompatibility(
            forProfile: "bsmanager-instance"))
        XCTAssertEqual(
            try manager.steamBootstrapCommand(
                forProfile: "bsmanager-instance")?.arguments,
            [
                #"C:\Program Files (x86)\Steam\steam.exe"#,
                "-inhibitbootstrap", "-noverifyfiles", "-no-cef-sandbox",
            ])
        XCTAssertEqual(
            try manager.steamConnectionLogURL(
                forProfile: "bsmanager-instance"),
            prefix.appendingPathComponent(
                "drive_c/Program Files (x86)/Steam/logs/connection_log.txt"))
    }

    func testImportsExternalPrefixIntoIsolatedManagedCopy() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltImport-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let pinned = temporary.appendingPathComponent(
            "runtime/build/dxmt/toolchain/wine-11.10/Wine Devel.app/Contents/Resources/wine")
        let bin = pinned.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["wine", "wineserver"] {
            let executable = bin.appendingPathComponent(name)
            // Import is a file operation and must never boot the copied prefix.
            // A Wine invocation makes this test fail immediately.
            try Data("#!/bin/sh\nexit 71\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let macDriver = pinned.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        try FileManager.default.createDirectory(
            at: macDriver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: macDriver)
        let fork = temporary.appendingPathComponent(
            "runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so")
        try FileManager.default.createDirectory(
            at: fork.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: fork)

        let source = temporary.appendingPathComponent("Whisky", isDirectory: true)
        let game = source.appendingPathComponent("drive_c/Games/Test/Game.exe")
        try FileManager.default.createDirectory(
            at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: game)
        try Data("WINE REGISTRY".utf8).write(to: source.appendingPathComponent("system.reg"))
        let sourceUserRegistry = #"""
        WINE REGISTRY Version 2

        [Software\\Microsoft\\Windows\\CurrentVersion\\Run]
        "Other"="C:\\Other.exe"
        "Steam"="\"C:\\Program Files (x86)\\Steam\\steam.exe\" -silent"

        [Software\\Valve\\Steam]
        "SuppressAutoRun"=dword:00000000
        """#
        try Data(sourceUserRegistry.utf8).write(
            to: source.appendingPathComponent("user.reg"))

        let manager = BottleManager(
            root: temporary.appendingPathComponent("data"), repoRoot: temporary)
        let imported = try manager.importPrefix(
            name: "imported", engineID: BottleEngineDiscovery.pinnedDXMTEngineID,
            sourcePrefix: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath:
            URL(fileURLWithPath: imported.prefixPath)
                .appendingPathComponent("drive_c/Games/Test/Game.exe").path))
        XCTAssertEqual(try Data(contentsOf:
            URL(fileURLWithPath: imported.prefixPath).appendingPathComponent("system.reg")),
            Data("WINE REGISTRY".utf8))
        let importedUserRegistry = try String(contentsOf:
            URL(fileURLWithPath: imported.prefixPath).appendingPathComponent("user.reg"))
        XCTAssertFalse(importedUserRegistry.contains(#""Steam"="#))
        XCTAssertTrue(importedUserRegistry.contains(
            #""SuppressAutoRun"=dword:00000001"#))
        XCTAssertTrue(importedUserRegistry.contains(#""Other"="C:\\Other.exe""#))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("user.reg")),
                       sourceUserRegistry, "The source registry must remain untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.path),
                      "The external source must remain untouched")
        XCTAssertFalse(imported.dxmtInstalled)
        XCTAssertFalse(imported.runtimeInstalled)
    }

    func testInstallDXMTMigratesLegacyPinnedEngineBeforeOverlay() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltEngineMigration-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let provider = temporary.appendingPathComponent(
            "runtime/build/dxmt/toolchain/wine-11.10/Wine Devel.app/Contents/Resources/wine",
            isDirectory: true)
        let providerWine = provider.appendingPathComponent("bin/wine")
        let providerServer = provider.appendingPathComponent("bin/wineserver")
        let providerMac = provider.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        for executable in [providerWine, providerServer] {
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        try FileManager.default.createDirectory(
            at: providerMac.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("matched-mac-driver".utf8).write(to: providerMac)

        let fork = temporary.appendingPathComponent("runtime/build/dxmt/fork-install")
        let forkWindows = fork.appendingPathComponent("x86_64-windows")
        let forkUnix = fork.appendingPathComponent("x86_64-unix/winemetal.so")
        try FileManager.default.createDirectory(
            at: forkWindows, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: forkUnix.deletingLastPathComponent(), withIntermediateDirectories: true)
        for dll in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"] {
            try Data("fork-\(dll)".utf8).write(to: forkWindows.appendingPathComponent(dll))
        }
        try Data("fork-unix".utf8).write(to: forkUnix)

        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Legacy", isDirectory: true)
        let engine = directory.appendingPathComponent("engine", isDirectory: true)
        let legacyWine = engine.appendingPathComponent("bin/wine")
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyWine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: legacyWine)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: legacyWine.path)
        try Data("legacy".utf8).write(to: engine.appendingPathComponent("legacy.marker"))

        let legacyProvider = BottleEngine(
            id: "pinned-wine-8.17-dxmt-0.80", kind: .pinned,
            wineBinary: legacyWine,
            wineserverBinary: engine.appendingPathComponent("bin/wineserver"),
            root: engine, supportsBasaltDXMT: true)
        var bottle = ManagedBottle(
            name: "Legacy", engine: legacyProvider, prefix: prefix,
            engineRoot: engine, wineBinary: legacyWine)
        bottle.dxmtInstalled = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))

        let manager = BottleManager(root: root, repoRoot: temporary)
        let migrated = try manager.installDXMT(in: "Legacy")

        XCTAssertEqual(migrated.engineID, BottleEngineDiscovery.pinnedDXMTEngineID)
        XCTAssertTrue(migrated.dxmtInstalled)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: engine.appendingPathComponent("legacy.marker").path))
        XCTAssertEqual(try String(contentsOf: engine.appendingPathComponent(
            "lib/wine/x86_64-unix/winemac.so")), "matched-mac-driver")
        XCTAssertEqual(try String(contentsOf: engine.appendingPathComponent(
            "lib/wine/x86_64-unix/winemetal.so")), "fork-unix")
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent(
            "drive_c/windows/system32/d3d11.dll")), "fork-d3d11.dll")
    }

    func testDeletesOnlyRequestedProfileAndBuildsMaintenanceCommand() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltProfileDelete-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("data")
        let directory = root.appendingPathComponent("Bottles/Test")
        let prefix = directory.appendingPathComponent("prefix")
        let engine = directory.appendingPathComponent("engine")
        let wine = engine.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let provider = BottleEngine(
            id: "test", kind: .pinned, wineBinary: wine,
            wineserverBinary: engine.appendingPathComponent("bin/wineserver"),
            root: engine, supportsBasaltDXMT: true)
        let bottle = ManagedBottle(
            name: "Test", engine: provider, prefix: prefix,
            engineRoot: engine, wineBinary: wine)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        let manager = BottleManager(root: root, repoRoot: temporary)
        try manager.saveProfile(LaunchProfile(
            name: "one", bottleName: "Test", source: .direct, executable: #"C:\one.exe"#))
        try manager.saveProfile(LaunchProfile(
            name: "two", bottleName: "Test", source: .direct, executable: #"C:\two.exe"#))

        try manager.deleteProfile("one")
        XCTAssertEqual(try manager.listProfiles().map(\.name), ["two"])
        let command = try manager.applicationLaunchCommand(
            bottleName: "Test", executable: #"C:\steam.exe"#, arguments: ["-silent"])
        XCTAssertEqual(command.arguments, [#"C:\steam.exe"#, "-silent"])
        XCTAssertEqual(command.environment["WINEPREFIX"], prefix.path)
    }

    func testReadsActiveOpenXRRuntimeFromWineHive() {
        let hive = #"""
            WINE REGISTRY Version 2
            ;; All keys relative to REGISTRY\\Machine

            [Software\\Khronos\\OpenXR\\1] 1784710400
            #time=1dd19b78b874098
            "ActiveRuntime"="C:\\basalt\\runtime\\basalt_openxr.json"

            [Software\\Khronos\\Vulkan\\Drivers] 1749700164
            "C:\\windows\\system32\\winevulkan.json"=dword:00000000
            """#
        XCTAssertEqual(
            BottleManager.activeOpenXRRuntime(inHive: Data(hive.utf8)),
            BottleManager.runtimeManifestWindowsPath)
        XCTAssertEqual(
            BottleManager.activeOpenXRRuntime(inHive: Data(hive.replacingOccurrences(
                of: #"C:\\basalt\\runtime\\basalt_openxr.json"#,
                with: #"C:\\Program Files\\SteamVR\\steamxr_win64.json"#).utf8)),
            #"C:\Program Files\SteamVR\steamxr_win64.json"#)
        XCTAssertNil(BottleManager.activeOpenXRRuntime(inHive: Data(hive.replacingOccurrences(
            of: "OpenXR", with: "OpenVR").utf8)))
        // Key names are case-insensitive.
        XCTAssertEqual(
            BottleManager.activeOpenXRRuntime(inHive: Data(hive.replacingOccurrences(
                of: "Software", with: "SOFTWARE").utf8)),
            BottleManager.runtimeManifestWindowsPath)
    }

    func testRuntimeSyncSkipsWineWhenTheBottleIsCurrent() throws {
        let temporary = try temporaryDirectory()
        let bin = temporary.appendingPathComponent("runtime/build/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("dll-v1".utf8).write(to: bin.appendingPathComponent("basalt_openxr.dll"))
        try Data("{}".utf8).write(to: bin.appendingPathComponent("basalt_openxr.json"))

        let manager = BottleManager(
            root: temporary.appendingPathComponent("data"), repoRoot: temporary)
        try manager.prepare()
        let directory = try manager.paths.bottleDirectory("Test")
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engine = directory.appendingPathComponent("engine", isDirectory: true)
        let wine = engine.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Records each Wine start; registration is the only one here.
        try Data("#!/bin/sh\necho \"$@\" >> \"$WINEPREFIX/wine-calls\"\n".utf8).write(to: wine)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let bottle = ManagedBottle(
            name: "Test",
            engine: BottleEngine(
                id: "test", kind: .pinned, wineBinary: wine,
                wineserverBinary: engine.appendingPathComponent("bin/wineserver"),
                root: engine, supportsBasaltDXMT: true),
            prefix: prefix, engineRoot: engine, wineBinary: wine)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        func wineStarts() -> Int {
            ((try? String(contentsOf: prefix.appendingPathComponent("wine-calls")))?
                .split(separator: "\n").count) ?? 0
        }

        // A first sync registers even without a hive.
        XCTAssertTrue(try manager.syncRuntime(in: "Test").runtimeInstalled)
        XCTAssertEqual(wineStarts(), 1)

        // Wine flushed the registration; an unchanged bottle needs no Wine.
        try Data(#"""

            [Software\\Khronos\\OpenXR\\1] 1784710400
            "ActiveRuntime"="C:\\basalt\\runtime\\basalt_openxr.json"

            """#.utf8).write(to: prefix.appendingPathComponent("system.reg"))
        try manager.syncRuntime(in: "Test")
        XCTAssertEqual(wineStarts(), 1)

        // A rebuilt DLL is still copied without re-registering.
        try Data("dll-v2".utf8).write(to: bin.appendingPathComponent("basalt_openxr.dll"))
        try manager.syncRuntime(in: "Test")
        XCTAssertEqual(wineStarts(), 1)
        XCTAssertEqual(try String(contentsOf: prefix.appendingPathComponent(
            "drive_c/basalt/runtime/basalt_openxr.dll")), "dll-v2")

        // Another runtime took over, and Prepare always re-registers.
        try Data(#"""

            [Software\\Khronos\\OpenXR\\1] 1784710400
            "ActiveRuntime"="C:\\SteamVR\\steamxr_win64.json"

            """#.utf8).write(to: prefix.appendingPathComponent("system.reg"))
        try manager.syncRuntime(in: "Test")
        XCTAssertEqual(wineStarts(), 2)
        _ = try manager.installRuntime(in: "Test")
        XCTAssertEqual(wineStarts(), 3)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltBottleKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
