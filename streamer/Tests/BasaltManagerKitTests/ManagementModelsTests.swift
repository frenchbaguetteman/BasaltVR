import XCTest
@testable import BasaltManagerKit
import BasaltBottleKit
import BasaltCore

final class ManagementModelsTests: XCTestCase {
    func testSteamConnectionLogUsesLatestStateAfterSnapshot() {
        let old = "[2026-01-01] [Logged On, 4, 7] ready\n"
        let coldStart = "[2026-01-02] [Logged Off, 0, 0] starting\n"
        let ready = "[2026-01-02] [Logged On, 4, 7] ready\n"
        let oldData = Data(old.utf8)

        XCTAssertEqual(
            SteamConnectionLog.state(in: oldData + Data(coldStart.utf8),
                                     after: oldData.count),
            .loggedOff)
        XCTAssertEqual(
            SteamConnectionLog.state(
                in: oldData + Data((coldStart + ready).utf8),
                after: oldData.count),
            .loggedOn)
        XCTAssertEqual(
            SteamConnectionLog.state(in: Data(coldStart.utf8), after: 10_000),
            .loggedOff)
    }

    func testDetectsBeatSaberAndInfersLaunchSource() throws {
        let temporary = try temporaryDirectory()
        let prefix = temporary.appendingPathComponent("prefix", isDirectory: true)
        let executable = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steamapps/common/Beat Saber/Beat Saber.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: executable)
        let bottle = makeBottle(name: "beat-saber", prefix: prefix)

        let games = GameDetector().detect(bottles: [bottle], profiles: [])

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].title, "Beat Saber")
        XCTAssertEqual(games[0].source, .steam)
        XCTAssertEqual(games[0].executable,
                       #"C:\Program Files (x86)\Steam\steamapps\common\Beat Saber\Beat Saber.exe"#)
        XCTAssertNil(games[0].profileName)
    }

    func testProfileWinsOverDuplicateDetectedExecutable() throws {
        let temporary = try temporaryDirectory()
        let prefix = temporary.appendingPathComponent("prefix", isDirectory: true)
        let executable = prefix.appendingPathComponent("drive_c/Games/Beat Saber/Beat Saber.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: executable)
        let bottle = makeBottle(name: "main", prefix: prefix)
        let profile = LaunchProfile(
            name: "my-beat-saber", bottleName: bottle.name, source: .direct,
            executable: #"C:\Games\Beat Saber\Beat Saber.exe"#)

        let games = GameDetector().detect(bottles: [bottle], profiles: [profile])

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].profileName, profile.name)
    }

    func testWindowsPathsMapBackIntoBottle() {
        let bottle = makeBottle(
            name: "main", prefix: URL(fileURLWithPath: "/tmp/Basalt/prefix"))
        XCTAssertEqual(
            GameDetector.hostURL(for: #"C:\Games\Test.exe"#, bottle: bottle)?.path,
            "/tmp/Basalt/prefix/drive_c/Games/Test.exe")
        XCTAssertEqual(
            GameDetector.hostURL(for: #"Z:\Users\me\Game.exe"#, bottle: bottle)?.path,
            "/Users/me/Game.exe")
        XCTAssertNil(GameDetector.hostURL(for: #"D:\Game.exe"#, bottle: bottle))
    }

    func testDiscoversDefaultLegacyAndConfiguredBSManagerInstances() throws {
        let home = try temporaryDirectory()
        let defaultInstance = home.appendingPathComponent(
            "BSManager/BSInstances/1.40.8", isDirectory: true)
        let legacyInstance = home.appendingPathComponent(
            "Documents/BSManager/BSInstances/My Modded Copy", isDirectory: true)
        let customParent = home.appendingPathComponent("External Games", isDirectory: true)
        let customInstance = customParent.appendingPathComponent(
            "BSManager/BSInstances/1.39.1", isDirectory: true)
        for instance in [defaultInstance, legacyInstance, customInstance] {
            try FileManager.default.createDirectory(
                at: instance, withIntermediateDirectories: true)
            try Data([0x4d, 0x5a]).write(
                to: instance.appendingPathComponent("Beat Saber.exe"))
        }
        try Data().write(to: legacyInstance.appendingPathComponent("IPA.exe"))
        let metadata = #"{"id":"instance-id","store":"steam"}"#
        try Data(metadata.utf8).write(
            to: customInstance.appendingPathComponent("metadata.config"))
        let config = home.appendingPathComponent(
            "Library/Application Support/BSManager/config.json")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let configData = try JSONSerialization.data(withJSONObject: [
            "installation-folder": customParent.path,
        ])
        try configData.write(to: config)

        let instances = BSManagerDiscovery(home: home).discover()

        XCTAssertEqual(instances.map(\.name), ["1.39.1", "1.40.8", "My Modded Copy"])
        XCTAssertEqual(instances.first { $0.name == "1.39.1" }?.metadataID, "instance-id")
        XCTAssertEqual(instances.first { $0.name == "1.39.1" }?.store, "steam")
        XCTAssertEqual(instances.first { $0.name == "My Modded Copy" }?.isModded, true)
        XCTAssertEqual(
            instances.first { $0.name == "1.40.8" }?.installationDirectory,
            home.appendingPathComponent("BSManager"))
    }

    func testDiscoversExplicitBSManagerParentVersionsFolderOrInstance() throws {
        let home = try temporaryDirectory()
        let parent = home.appendingPathComponent("Portable", isDirectory: true)
        let instance = parent.appendingPathComponent(
            "BSManager/BSInstances/Custom", isDirectory: true)
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(
            to: instance.appendingPathComponent("Beat Saber.exe"))
        try FileManager.default.createDirectory(
            at: instance.appendingPathComponent("Not A Game"), withIntermediateDirectories: true)

        let discovery = BSManagerDiscovery(home: home)

        XCTAssertEqual(discovery.discover(additionalLocations: [parent]).count, 1)
        XCTAssertEqual(
            discovery.discover(additionalLocations: [
                parent.appendingPathComponent("BSManager/BSInstances"),
            ]).count,
            1)
        XCTAssertEqual(discovery.discover(additionalLocations: [instance]).count, 1)
    }

    func testDiscoversBSManagerLauncherAndInstancesInsideManagedBottle() throws {
        let temporary = try temporaryDirectory()
        let prefix = temporary.appendingPathComponent("prefix", isDirectory: true)
        let windowsHome = prefix.appendingPathComponent(
            "drive_c/users/steamuser", isDirectory: true)
        let launcher = windowsHome.appendingPathComponent(
            "AppData/Local/Programs/bs-manager/BSManager.exe")
        let instance = windowsHome.appendingPathComponent(
            "BSManager/BSInstances/1.40.8", isDirectory: true)
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: instance, withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: launcher)
        try Data([0x4d, 0x5a]).write(
            to: instance.appendingPathComponent("Beat Saber.exe"))
        let bottle = makeBottle(name: "beat-saber", prefix: prefix)

        let installations = BSManagerInstallationDiscovery().discover(in: [bottle])
        let instances = BSManagerDiscovery(home: temporary).discover(bottles: [bottle])

        XCTAssertEqual(installations, [
            BSManagerInstallation(bottleName: bottle.name, executable: launcher),
        ])
        XCTAssertEqual(instances.count, 1)
        XCTAssertEqual(instances[0].bottleName, bottle.name)
        XCTAssertEqual(instances[0].name, "1.40.8")
    }

    func testStreamArgumentsAndLogMetricParsing() {
        var settings = StreamLaunchSettings()
        XCTAssertEqual(settings.connection, .wired)
        XCTAssertEqual(settings.fps, 72)
        XCTAssertEqual(settings.megabits, 30)
        XCTAssertEqual(settings.resolution, .quality)
        XCTAssertEqual(settings.latency, .low)
        settings.fps = 80
        settings.megabits = 18
        settings.resolution = .quality
        settings.latency = .ultra
        settings.audioDeviceName = "BlackHole 2ch"
        XCTAssertEqual(settings.arguments, [
            "--wired", "--fps", "80", "--mbps", "18",
            "--resolution", "quality", "--latency", "ultra",
            "--audio-device", "BlackHole 2ch", "--route-audio",
        ])
        settings.connection = .wifi
        XCTAssertEqual(settings.arguments.first, "--wireless")
        XCTAssertEqual(settings.connection.label, "Wireless (Wi-Fi)")

        let date = Date(timeIntervalSince1970: 10)
        let transport = StreamLogMetricsParser.parse(
            line: "  USB video send: 71.9 fps, 12.4 Mbps on wire", date: date)
        XCTAssertNil(transport?.fps)
        XCTAssertEqual(transport?.megabits, 12.4)
        XCTAssertNil(StreamLogMetricsParser.parse(
            line: "  USB audio send: 50 packets, 1.5 Mbps on wire", date: date))
        let quest = StreamLogMetricsParser.parse(
            line: "  Quest 72.0 fps; input→display latency: 49.2 ms average", date: date)
        XCTAssertEqual(quest?.fps, 72)
        XCTAssertEqual(quest?.latencyMilliseconds, 49.2)
        XCTAssertNil(StreamLogMetricsParser.parse(line: "tracking ready", date: date))
    }

    func testResolutionPresetsMatchTheStreamerParser() throws {
        for preset in ResolutionSelection.allCases {
            XCTAssertEqual(preset.perEyeResolution, try PerEyeResolution.parse(preset.rawValue))
        }
        XCTAssertEqual(ResolutionSelection.quality.dimensions, "1344 × 1408")
        XCTAssertEqual(ResolutionSelection.performance.label, "Performance · 896 × 944")
    }

    func testExtractsLastActionableStreamerError() {
        let log = """
        Starting USB cable streamer…
        ALVR USB handshake attempt 1 failed; retrying…
        error: ALVR is paused behind the Quest lock screen. Put on the headset.
        (If this is a capture error, grant Screen Recording permission.)
        """
        XCTAssertEqual(
            StreamerLogFailure.message(in: log),
            "ALVR is paused behind the Quest lock screen. Put on the headset.")
        XCTAssertNil(StreamerLogFailure.message(in: "Starting…\n"))
    }

    func testSurfacesRefusedRuntimeConnection() {
        let line = RuntimeLink.connectionRefusedLogPrefix
            + "OpenXR runtime speaks control protocol v7, but this streamer speaks v9"
        XCTAssertEqual(
            RuntimeConnectionRefusal.message(in: line + "\n"),
            "The game's OpenXR runtime was refused: "
                + "OpenXR runtime speaks control protocol v7, but this streamer speaks v9")
        XCTAssertNil(RuntimeConnectionRefusal.message(in: RuntimeLink.connectionRefusedLogPrefix))
        XCTAssertNil(RuntimeConnectionRefusal.message(in: "OpenXR runtime disconnected"))
    }

    func testDiscoversWhiskyAndCrossOverBottlesWithFriendlyNames() throws {
        let home = try temporaryDirectory()
        let whisky = home.appendingPathComponent(
            "Library/Containers/com.isaacmarovitz.Whisky/Bottles/UUID", isDirectory: true)
        let crossover = home.appendingPathComponent(
            "Library/Application Support/CrossOver/Bottles/Steam VR", isDirectory: true)
        for prefix in [whisky, crossover] {
            try FileManager.default.createDirectory(
                at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
            try Data().write(to: prefix.appendingPathComponent("system.reg"))
        }
        let metadata: [String: Any] = ["info": ["name": "My Whisky Games"]]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: metadata, format: .binary, options: 0)
        try plist.write(to: whisky.appendingPathComponent("Metadata.plist"))

        let bottles = ExternalBottleDiscovery(home: home).discover()

        XCTAssertEqual(bottles.map(\.name).sorted(), ["My Whisky Games", "Steam VR"])
        XCTAssertEqual(Set(bottles.map(\.origin)), Set([.whisky, .crossover]))
        XCTAssertTrue(bottles.allSatisfy { !$0.isManaged && !$0.isReadyForVR })
    }

    func testDiscoversInstalledSteamManifestAndArtwork() throws {
        let temporary = try temporaryDirectory()
        let prefix = temporary.appendingPathComponent("Bottle", isDirectory: true)
        let steam = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam", isDirectory: true)
        let steamApps = steam.appendingPathComponent("steamapps", isDirectory: true)
        let install = steamApps.appendingPathComponent("common/Beat Saber", isDirectory: true)
        let art = steam.appendingPathComponent(
            "appcache/librarycache/620980/library_600x900.jpg")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: art.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: steam.appendingPathComponent("steam.exe"))
        try Data([0xff, 0xd8]).write(to: art)
        let manifest = #"""
        "AppState"
        {
            "appid" "620980"
            "name" "Beat Saber"
            "installdir" "Beat Saber"
            "SizeOnDisk" "1655396478"
            "LastPlayed" "1000"
        }
        """#
        try Data(manifest.utf8).write(
            to: steamApps.appendingPathComponent("appmanifest_620980.acf"))
        let bottle = DiscoveredBottle(
            name: "Steam", origin: .crossover, prefix: prefix)

        let games = SteamLibraryDiscovery().discover(in: [bottle])

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].appID, "620980")
        XCTAssertEqual(games[0].name, "Beat Saber")
        XCTAssertEqual(games[0].sizeOnDisk, 1_655_396_478)
        XCTAssertEqual(games[0].lastPlayed, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(games[0].artwork, art.standardizedFileURL)
        XCTAssertTrue(games[0].isKnownVRGame)
    }

    func testVDFParserHandlesEscapedWindowsPaths() {
        let vdf = #"""
        "path" "D:\\SteamLibrary"
        "path" "E:\\More Games"
        """#
        XCTAssertEqual(
            SteamLibraryDiscovery.values(for: "path", in: vdf),
            [#"D:\SteamLibrary"#, #"E:\More Games"#])
    }

    private func makeBottle(name: String, prefix: URL) -> ManagedBottle {
        let root = prefix.deletingLastPathComponent().appendingPathComponent("engine")
        let engine = BottleEngine(
            id: "test", kind: .pinned,
            wineBinary: root.appendingPathComponent("bin/wine"),
            wineserverBinary: root.appendingPathComponent("bin/wineserver"),
            root: root, supportsBasaltDXMT: true)
        return ManagedBottle(
            name: name, engine: engine, prefix: prefix,
            engineRoot: root, wineBinary: root.appendingPathComponent("bin/wine"))
    }
}
