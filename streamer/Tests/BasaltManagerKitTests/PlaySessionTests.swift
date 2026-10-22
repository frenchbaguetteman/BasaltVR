import Foundation
import XCTest
import BasaltBottleKit
import BasaltCore
@testable import BasaltManagerKit

final class PlayLaunchPlanTests: XCTestCase {
    private let tools = PlayTools(
        repoRoot: URL(fileURLWithPath: "/repo", isDirectory: true),
        binDirectory: URL(fileURLWithPath: "/repo/streamer/.build/release", isDirectory: true))

    private func plan(_ transport: PlayTransport, _ quality: PlayQuality,
                      questLog: Bool = true) -> PlayLaunchPlan {
        PlayLaunchPlan.make(
            profile: "the-lab",
            options: PlayOptions(transport: transport, quality: quality, saveQuestLog: questLog),
            tools: tools, dataRoot: URL(fileURLWithPath: "/data"), parentPID: 4242)
    }

    /// The app's two quality levels on every transport. play.zsh turns these flags into
    /// streamer arguments; PlaySessionRunnerTests checks that end to end.
    func testArgumentsForEveryTransportAndQuality() {
        let expected: [PlayTransport: [PlayQuality: [String]]] = [
            .auto: [.high: ["--quality", "high", "--codec", "hevc", "the-lab"],
                    .normal: ["--quality", "normal", "the-lab"]],
            .usb: [.high: ["--usb", "--quality", "high", "--codec", "hevc", "the-lab"],
                   .normal: ["--usb", "--quality", "normal", "the-lab"]],
            .wifi: [.high: ["--wifi", "--quality", "high", "--codec", "hevc", "the-lab"],
                    .normal: ["--wifi", "--quality", "normal", "the-lab"]],
        ]
        for transport in PlayTransport.allCases {
            for quality in PlayQuality.allCases {
                let plan = plan(transport, quality)
                XCTAssertEqual(plan.executable.path, "/bin/zsh")
                XCTAssertEqual(plan.arguments.first, "/repo/scripts/play.zsh")
                XCTAssertEqual(Array(plan.arguments.dropFirst()), expected[transport]?[quality],
                               "\(transport) \(quality)")
                XCTAssertEqual(plan.environment["BASALT_WIFI_MBPS"],
                               quality == .high ? "50" : nil, "\(transport) \(quality)")
                XCTAssertEqual(plan.currentDirectory.path, "/repo")
            }
        }
    }

    func testQuestLogCanBeTurnedOff() {
        XCTAssertEqual(plan(.usb, .high, questLog: false).arguments.suffix(2),
                       ["--no-log-quest", "the-lab"])
    }

    func testEnvironmentNamesTheToolsAndTheApp() {
        let environment = plan(.auto, .high).environment
        XCTAssertEqual(environment["BASALT_PLAY_EVENTS"], "1")
        XCTAssertEqual(environment["BASALT_PLAY_PARENT_PID"], "4242")
        XCTAssertEqual(environment["BASALT_REPO_ROOT"], "/repo")
        XCTAssertEqual(environment["BASALT_BIN_DIR"], "/repo/streamer/.build/release")
        XCTAssertEqual(environment["BASALT_DATA_DIR"], "/data")
    }

    func testShellVariablesCannotOverrideTheAppsChoice() {
        let base = [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/me",
            "BASALT_TRANSPORT": "usb", "BASALT_QUALITY": "max", "BASALT_CODEC": "h264",
            "BASALT_WIFI_MBPS": "10",
            "ELECTRON_RUN_AS_NODE": "1",
        ]
        let normal = plan(.wifi, .normal).processEnvironment(base: base)
        for key in ["BASALT_TRANSPORT", "BASALT_QUALITY", "BASALT_CODEC", "BASALT_WIFI_MBPS",
                    "ELECTRON_RUN_AS_NODE"] {
            XCTAssertNil(normal[key], key)
        }
        XCTAssertEqual(normal["HOME"], "/Users/me")
        XCTAssertEqual(plan(.wifi, .high).processEnvironment(base: base)["BASALT_WIFI_MBPS"], "50")
    }

    func testSearchPathKeepsOrderAndAddsHomebrew() {
        XCTAssertEqual(PlayLaunchPlan.searchPath("/usr/bin:/bin:/usr/sbin:/sbin"),
                       "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
        XCTAssertEqual(PlayLaunchPlan.searchPath("/fake:/opt/homebrew/bin"),
                       "/fake:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(PlayLaunchPlan.searchPath(nil),
                       "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testToolsPreferTheAppFolderOnlyWhenItHoldsBothTools() throws {
        let root = try temporaryDirectory()
        let appFolder = root.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        let checkout = PlayTools.locate(repoRoot: root, appExecutableDirectory: appFolder)
        XCTAssertEqual(checkout.binDirectory.path,
                       root.appendingPathComponent("streamer/.build/release").path)
        XCTAssertEqual(checkout.playScript.path, root.appendingPathComponent("scripts/play.zsh").path)
        for name in ["basalt-streamer", "basaltctl"] {
            let file = appFolder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        XCTAssertEqual(PlayTools.locate(repoRoot: root, appExecutableDirectory: appFolder)
            .binDirectory.path, appFolder.path)
    }
}

final class PlayEventTests: XCTestCase {
    func testParsesEveryEvent() {
        let cases: [(String, PlayEvent)] = [
            ("@@basalt start the-lab", .start(profile: "the-lab")),
            ("@@basalt looking", .looking),
            ("@@basalt wifi-reconnect 192.168.1.20", .wifiReconnect(ip: "192.168.1.20")),
            ("@@basalt connection usb", .connection(.usb)),
            ("@@basalt connection wifi", .connection(.wifi)),
            ("@@basalt quality high: 1344x1408 per eye, 72 fps, 60 Mbps, hevc",
             .quality("high: 1344x1408 per eye, 72 fps, 60 Mbps, hevc")),
            ("@@basalt log streamer /Users/me/Library/Logs/BasaltVR/streamer 1.log",
             .log(kind: "streamer", path: "/Users/me/Library/Logs/BasaltVR/streamer 1.log")),
            ("@@basalt alvr-restart", .alvrRestart),
            ("@@basalt streamer-start", .streamerStart),
            ("@@basalt open-alvr", .openALVR),
            ("@@basalt steam-start", .steamStart),
            ("@@basalt headset-wait", .headsetWait),
            ("@@basalt headset-ready", .headsetReady),
            ("@@basalt game-start the-lab", .gameStart(profile: "the-lab")),
            (#"@@basalt game-child RobotRepair\bin\win64\vr.exe"#,
             .gameChild(path: #"RobotRepair\bin\win64\vr.exe"#)),
            ("@@basalt game-ended 0", .gameEnded(status: 0)),
            ("@@basalt stopping", .stopping),
            ("@@basalt stopped", .stopped),
            ("@@basalt fail no-usb-quest", .fail(.noUSBQuest)),
            ("@@basalt fail wifi-timeout", .fail(.wifiTimeout)),
            ("@@basalt fail something-new", .fail(.unknown)),
        ]
        for (line, event) in cases {
            XCTAssertEqual(PlayEvent.parse(line), event, line)
        }
    }

    func testIgnoresHumanLinesAndUnknownEvents() {
        XCTAssertNil(PlayEvent.parse("Starting the streamer. Put the headset on."))
        XCTAssertNil(PlayEvent.parse("@@basalt"))
        XCTAssertNil(PlayEvent.parse("@@basalt teleport now"))
        XCTAssertNil(PlayEvent.parse("@@basalt connection bluetooth"))
        XCTAssertNil(PlayEvent.parse("@@basalt log streamer"))
    }

    func testEveryFailureHasAPlainSentence() {
        for code in ["build", "profile", "no-adb", "quest-unauthorized", "no-usb-quest",
                     "alvr-missing", "streamer-running", "streamer-stopped",
                     "streamer-timeout", "wifi-timeout", "game-error"] {
            let failure = PlayFailure(rawValue: code)
            XCTAssertNotNil(failure, code)
            XCTAssertFalse(failure?.message.contains("scripts/") ?? true, code)
            XCTAssertTrue(failure?.message.hasSuffix(".") ?? false, code)
        }
    }
}

final class PlayProgressTests: XCTestCase {
    private func run(_ events: [PlayEvent], streamer: [String] = [],
                     title: String = "The Lab") -> PlayProgress {
        var progress = PlayProgress()
        progress.begin(gameTitle: title)
        events.forEach { progress.apply($0) }
        streamer.forEach { progress.apply(streamerLine: $0) }
        return progress
    }

    func testHappyPathOverUSB() {
        var progress = PlayProgress()
        XCTAssertFalse(progress.isActive)
        XCTAssertEqual(progress.headline, "Ready to play")
        progress.begin(gameTitle: "The Lab")
        XCTAssertTrue(progress.isActive)
        XCTAssertEqual(progress.headline, "Looking for your Quest…")
        progress.apply(.start(profile: "the-lab"))
        progress.apply(.looking)
        XCTAssertEqual(progress.headline, "Looking for your Quest…")
        progress.apply(.connection(.usb))
        XCTAssertEqual(progress.link, .usb)
        progress.apply(.log(kind: "streamer", path: "/logs/streamer-1.log"))
        XCTAssertEqual(progress.streamerLog?.path, "/logs/streamer-1.log")
        progress.apply(.alvrRestart)
        XCTAssertEqual(progress.headline, "Getting ALVR ready on your Quest…")
        progress.apply(.streamerStart)
        XCTAssertEqual(progress.phase, .connecting)
        XCTAssertEqual(progress.headline, "Put on your headset")
        progress.apply(.steamStart)
        XCTAssertTrue(progress.detail.contains("Steam is starting"))
        progress.apply(.headsetWait)
        progress.apply(.headsetReady)
        XCTAssertEqual(progress.headline, "Headset connected")
        progress.apply(.gameStart(profile: "the-lab"))
        XCTAssertEqual(progress.phase, .starting)
        XCTAssertEqual(progress.headline, "Starting The Lab…")
        progress.apply(streamerLine: "OpenXR runtime connected (session 1, d3d11)")
        XCTAssertEqual(progress.phase, .playing)
        XCTAssertEqual(progress.headline, "Playing The Lab")
        progress.apply(.gameChild(path: #"RobotRepair\bin\win64\vr.exe"#))
        XCTAssertEqual(progress.detail, "RobotRepair is running.")
        progress.apply(.gameEnded(status: 0))
        XCTAssertEqual(progress.headline, "The game ended")
        progress.apply(.stopping)
        progress.apply(.stopped)
        XCTAssertEqual(progress.phase, .finished)
        XCTAssertEqual(progress.headline, "The game ended")
        XCTAssertFalse(progress.isActive)
        progress.finish(exitStatus: 0, lastError: nil)
        XCTAssertEqual(progress.headline, "The game ended")
    }

    func testWiFiAsksToOpenALVR() {
        let progress = run([.connection(.wifi), .streamerStart, .openALVR])
        XCTAssertEqual(progress.headline, "Put on your headset")
        XCTAssertTrue(progress.detail.contains("Open ALVR on your Quest"))
    }

    func testDisconnectAndReconnectWhilePlaying() {
        var progress = run([.connection(.wifi), .headsetReady, .gameStart(profile: "the-lab")],
                           streamer: ["OpenXR runtime connected (session 1, d3d11)"])
        progress.apply(streamerLine: "ALVR headset disconnected (timeout). The OpenXR runtime keeps running; waiting for ALVR to reconnect over Wi-Fi…")
        XCTAssertEqual(progress.phase, .reconnecting)
        XCTAssertEqual(progress.headline, "Quest disconnected — reconnecting…")
        XCTAssertTrue(progress.isActive)
        progress.apply(streamerLine: "ALVR headset reconnected (session 2); sent a fresh IDR")
        XCTAssertEqual(progress.phase, .playing)
        XCTAssertEqual(progress.headline, "Playing The Lab")
    }

    func testReconnectBeforeTheGameGoesBackToConnecting() {
        var progress = run([.connection(.usb), .streamerStart],
                           streamer: ["ALVR headset disconnected (closed)"])
        XCTAssertEqual(progress.phase, .reconnecting)
        progress.apply(streamerLine: "ALVR headset reconnected (session 2)")
        XCTAssertEqual(progress.phase, .connecting)
    }

    func testRuntimeConnectBeforeGameStartIsIgnored() {
        let progress = run([.streamerStart], streamer: ["OpenXR runtime connected (session 1)"])
        XCTAssertEqual(progress.phase, .connecting)
    }

    func testFailureKeepsItsMessageThroughCleanup() {
        var progress = run([.looking, .fail(.noUSBQuest), .stopping])
        XCTAssertEqual(progress.phase, .failed)
        XCTAssertEqual(progress.headline, PlayFailure.noUSBQuest.message)
        XCTAssertFalse(progress.isActive)
        progress.apply(.stopped)
        progress.finish(exitStatus: 1, lastError: "I cannot see the Quest")
        XCTAssertEqual(progress.phase, .failed)
        XCTAssertEqual(progress.failure, .noUSBQuest)
        XCTAssertEqual(progress.headline, PlayFailure.noUSBQuest.message)
        XCTAssertEqual(progress.detail, "")
    }

    func testStreamerLinesAfterAFailureChangeNothing() {
        var progress = run([.gameStart(profile: "x"), .fail(.streamerStopped)])
        progress.apply(streamerLine: "ALVR headset reconnected (session 2)")
        XCTAssertEqual(progress.phase, .failed)
    }

    func testUserStop() {
        var progress = run([.connection(.usb), .headsetReady, .gameStart(profile: "the-lab")])
        progress.requestStop()
        XCTAssertEqual(progress.phase, .stopping)
        XCTAssertEqual(progress.headline, "Stopping…")
        XCTAssertTrue(progress.isActive)
        progress.apply(streamerLine: "OpenXR runtime connected (session 1)")
        progress.apply(.gameChild(path: "x.exe"))
        XCTAssertEqual(progress.phase, .stopping, "late events must not undo Stop")
        progress.apply(.stopping)
        progress.apply(.stopped)
        progress.finish(exitStatus: 130, lastError: nil)
        XCTAssertEqual(progress.phase, .finished)
        XCTAssertEqual(progress.headline, "Stopped")
    }

    func testStopRequestedWhileIdleDoesNothing() {
        var progress = PlayProgress()
        progress.requestStop()
        XCTAssertEqual(progress.phase, .idle)
    }

    func testCrashWithoutEventsIsAFailureWithTheLastError() {
        var progress = run([.looking])
        progress.finish(exitStatus: 1, lastError: "zsh: command not found: jq")
        XCTAssertEqual(progress.phase, .failed)
        XCTAssertEqual(progress.headline, "Something went wrong")
        XCTAssertEqual(progress.detail, "zsh: command not found: jq See Details.")
        XCTAssertEqual(progress.failure, .unknown)
    }

    func testQuitDuringASessionStillFinishes() {
        var progress = run([.connection(.usb)])
        progress.finish(exitStatus: 0, lastError: nil)
        XCTAssertEqual(progress.phase, .finished)
    }

    func testProgramNames() {
        XCTAssertEqual(PlayProgress.programName(#"RobotRepair\bin\win64\vr.exe"#), "RobotRepair")
        XCTAssertEqual(PlayProgress.programName("SecretShop.exe"), "SecretShop")
        XCTAssertEqual(PlayProgress.programName("a/b.exe"), "a")
    }
}

final class PlayLiveStatsTests: XCTestCase {
    func testReadsTheStreamerReportLines() {
        var stats = PlayLiveStats()
        XCTAssertTrue(stats.isEmpty)
        XCTAssertFalse(stats.apply(streamerLine: "ALVR control accepted by 'Quest 3'"))
        XCTAssertTrue(stats.apply(streamerLine: StreamReport.questLine(
            framesPerSecond: 71.6, averageLatencyMilliseconds: 68.2,
            maximumLatencyMilliseconds: 90, decodeMilliseconds: 10,
            decoderQueueMilliseconds: 1, vsyncQueueMilliseconds: 2)))
        XCTAssertEqual(stats.framesPerSecond ?? 0, 71.6, accuracy: 0.01)
        XCTAssertEqual(stats.latencyMilliseconds ?? 0, 68.2, accuracy: 0.01)
        XCTAssertTrue(stats.apply(streamerLine: StreamReport.videoSendLine(
            transport: "USB", framesPerSecond: 72, megabitsPerSecond: 58.5,
            maximumWriteMilliseconds: 3, largestFrameKibibytes: 200, idrCount: 1,
            repeatedTimestamps: 0)))
        XCTAssertEqual(stats.megabits ?? 0, 58.5, accuracy: 0.01)
        XCTAssertEqual(stats.framesPerSecond ?? 0, 71.6, accuracy: 0.01, "kept")
    }
}

final class PlayLibraryTests: XCTestCase {
    private func steamGame(_ appID: String, _ name: String, folder: String,
                           bottle: DiscoveredBottle, artwork: URL?) -> SteamGame {
        SteamGame(
            appID: appID, name: name, bottle: bottle,
            installDirectory: bottle.prefix.appendingPathComponent(
                "drive_c/Program Files (x86)/Steam/steamapps/common/\(folder)"),
            steamExecutable: bottle.prefix.appendingPathComponent(
                "drive_c/Program Files (x86)/Steam/steam.exe"),
            artwork: artwork, sizeOnDisk: nil, lastPlayed: nil)
    }

    private func bottle(_ name: String, origin: BottleOrigin = .managed) -> DiscoveredBottle {
        DiscoveredBottle(
            name: name, origin: origin,
            prefix: URL(fileURLWithPath: "/b/\(name)/prefix", isDirectory: true))
    }

    private let lab = LaunchProfile(
        name: "the-lab", bottleName: "pcvr", source: .steam,
        executable: #"C:\Program Files (x86)\Steam\steamapps\common\The Lab\TheLab\win64\TheLab.exe"#,
        arguments: ["-popupwindow"],
        environment: ["SteamAppId": "450390", "SteamGameId": "450390"])
    private let beatSaber = LaunchProfile(
        name: "beat-saber-steam", bottleName: "pcvr", source: .steam,
        executable: #"C:\Program Files (x86)\Steam\steam.exe"#,
        arguments: ["-applaunch", "620980", "-cef-disable-gpu-compositing"])
    private let steamClient = LaunchProfile(
        name: "steam", bottleName: "pcvr", source: .steam,
        executable: #"C:\Program Files (x86)\Steam\steam.exe"#,
        arguments: ["-cef-disable-gpu-compositing"])

    func testTilesFromTheVerifiedProfilesWithSteamArtwork() {
        let pcvr = bottle("pcvr")
        let art = URL(fileURLWithPath: "/b/pcvr/librarycache/450390/library_600x900.jpg")
        let other = LaunchProfile(name: "my-game", bottleName: "pcvr", source: .direct,
                                  executable: #"C:\Games\Thing\thing.exe"#)
        let games = PlayLibrary.games(
            profiles: [other, steamClient, beatSaber, lab],
            steamGames: [steamGame("450390", "The Lab", folder: "The Lab", bottle: pcvr, artwork: art)])
        XCTAssertEqual(games.map(\.profileName), ["beat-saber-steam", "the-lab", "my-game"])
        XCTAssertEqual(games.map(\.title), ["Beat Saber", "The Lab", "My Game"])
        XCTAssertEqual(games[1].artwork, art)
        XCTAssertEqual(games[1].appID, "450390")
        XCTAssertTrue(games[0].isVerified)
        XCTAssertTrue(games[1].isVerified)
        XCTAssertFalse(games[2].isVerified)
        XCTAssertNil(games[0].artwork)
    }

    func testMatchesByInstallFolderAndOnlyInTheSameManagedBottle() {
        let noID = LaunchProfile(
            name: "lab-no-id", bottleName: "pcvr", source: .steam,
            executable: #"C:\Program Files (x86)\Steam\steamapps\common\The Lab\TheLab\win64\TheLab.exe"#)
        let art = URL(fileURLWithPath: "/art.jpg")
        let games = PlayLibrary.games(profiles: [noID], steamGames: [
            steamGame("450390", "The Lab (Whisky)", folder: "The Lab",
                      bottle: bottle("pcvr", origin: .whisky), artwork: URL(fileURLWithPath: "/no.jpg")),
            steamGame("450390", "The Lab (other)", folder: "The Lab",
                      bottle: bottle("other"), artwork: URL(fileURLWithPath: "/no.jpg")),
            steamGame("450390", "The Lab", folder: "the lab", bottle: bottle("pcvr"), artwork: art),
        ])
        XCTAssertEqual(games.first?.title, "The Lab")
        XCTAssertEqual(games.first?.artwork, art)
        XCTAssertEqual(games.first?.appID, "450390")
        XCTAssertTrue(games.first?.isVerified ?? false)
    }

    func testProfileHelpers() {
        XCTAssertEqual(PlayLibrary.appID(for: beatSaber), "620980")
        XCTAssertEqual(PlayLibrary.appID(for: lab), "450390")
        XCTAssertNil(PlayLibrary.appID(for: steamClient))
        XCTAssertEqual(PlayLibrary.steamFolder(for: lab), "The Lab")
        XCTAssertNil(PlayLibrary.steamFolder(for: beatSaber))
        XCTAssertTrue(PlayLibrary.isSteamClientOnly(steamClient))
        XCTAssertFalse(PlayLibrary.isSteamClientOnly(beatSaber))
        XCTAssertFalse(PlayLibrary.isSteamClientOnly(lab))
        XCTAssertEqual(PlayLibrary.displayName("beat_saber-mods"), "Beat Saber Mods")
    }
}

final class QuestStatusTests: XCTestCase {
    func testParsesAUSBQuestWithALVR() {
        let status = QuestStatus.parse("""
            saved_ip=192.168.1.20
            adb=/opt/homebrew/bin/adb
            status=ok
            link=usb
            serial=QUEST3SERIAL01
            model=Quest_3
            reason=USB Quest QUEST3SERIAL01 (Quest_3); a USB Quest always wins. Ignored: emulator-5554 emulator.
            alvr=alvr.client.stable 20.14.1
            """)
        XCTAssertEqual(status.state, .ok)
        XCTAssertEqual(status.link, .usb)
        XCTAssertEqual(status.serial, "QUEST3SERIAL01")
        XCTAssertEqual(status.displayModel, "Quest 3")
        XCTAssertEqual(status.savedIP, "192.168.1.20")
        XCTAssertEqual(status.adbPath, "/opt/homebrew/bin/adb")
        XCTAssertEqual(status.alvr, .ready)
        XCTAssertTrue(status.reason?.contains("a USB Quest always wins") ?? false)
    }

    func testALVRStates() {
        XCTAssertEqual(QuestStatus.parse("status=ok\nlink=wifi").alvr, .missing)
        XCTAssertEqual(QuestStatus.parse("status=ok\nalvr=alvr.client.stable 20.6.0").alvr,
                       .otherVersion("20.6.0"))
        XCTAssertEqual(QuestStatus.parse("status=ok\nalvr=alvr.client.dev 20.14.1").alvr,
                       .otherVersion("20.14.1"))
        XCTAssertEqual(QuestStatus.parse("status=ok\nalvr=alvr.client.dev 21.0.0\nalvr=alvr.client.stable 20.14.1").alvr,
                       .ready)
        XCTAssertEqual(QuestStatus.parse("status=unauthorized\nalvr=alvr.client.stable 20.14.1").alvr,
                       .unknown)
        XCTAssertEqual(QuestStatus.parse("").state, .unknown)
        XCTAssertEqual(QuestStatus.parse("status=no-adb\nsaved_ip=").state, .noADB)
        XCTAssertNil(QuestStatus.parse("status=no-adb\nsaved_ip=").savedIP)
        XCTAssertEqual(QuestStatus.parse("status=none").displayModel, "Your Quest")
    }
}

final class PlayReadinessTests: XCTestCase {
    private let blackHole = GameAudioDevice(id: 1, name: "BlackHole 2ch", sampleRate: 48_000)

    private func items(_ quest: String, _ transport: PlayTransport = .auto,
                       audio: [GameAudioDevice]? = nil,
                       microphone: MicrophoneAccessState = .authorized) -> [PlayReadinessItem] {
        PlayReadiness.items(quest: QuestStatus.parse(quest), transport: transport,
                            audioDevices: audio ?? [blackHole], microphone: microphone)
    }

    private func item(_ id: String, in list: [PlayReadinessItem]) -> PlayReadinessItem? {
        list.first { $0.id == id }
    }

    func testEverythingReady() {
        let list = items("status=ok\nlink=usb\nmodel=Quest_3\nalvr=alvr.client.stable 20.14.1")
        XCTAssertEqual(list.map(\.id), ["quest", "alvr", "sound", "microphone"])
        XCTAssertTrue(list.allSatisfy { $0.level == .ready })
        XCTAssertEqual(item("quest", in: list)?.fix, .useWithoutCable)
        XCTAssertEqual(item("quest", in: list)?.detail, "Quest 3 is connected with the USB cable.")
    }

    func testQuestStates() {
        XCTAssertEqual(item("quest", in: items("status=unauthorized"))?.level, .blocking)
        XCTAssertNil(item("quest", in: items("status=unauthorized"))?.fix)
        let wifiOnlyAuto = item("quest", in: items("status=ok\nlink=wifi"))
        XCTAssertEqual(wifiOnlyAuto?.level, .ready)
        XCTAssertEqual(item("quest", in: items("status=ok\nlink=wifi", .usb))?.level, .blocking)
        let noneSaved = item("quest", in: items("status=none\nsaved_ip=10.0.0.5"))
        XCTAssertEqual(noneSaved?.level, .warning)
        XCTAssertEqual(noneSaved?.fix, .reconnectWiFi)
        XCTAssertEqual(item("quest", in: items("status=none", .usb))?.level, .blocking)
        XCTAssertNil(item("quest", in: items("status=none"))?.fix)
        XCTAssertEqual(item("quest", in: items("status=no-adb"))?.fix, .installADB)
        XCTAssertEqual(item("quest", in: items("status=no-adb", .wifi))?.level, .warning)
        XCTAssertEqual(item("quest", in: items(""))?.level, .unknown)
    }

    func testALVRFixes() {
        XCTAssertEqual(item("alvr", in: items("status=ok\nlink=usb"))?.fix, .installALVR)
        XCTAssertEqual(item("alvr", in: items("status=ok\nlink=usb"))?.level, .blocking)
        XCTAssertEqual(item("alvr", in: items("status=ok\nlink=usb\nalvr=alvr.client.stable 20.6.0"))?.fix,
                       .replaceALVR(installedVersion: "20.6.0"))
        XCTAssertEqual(item("alvr", in: items("status=none"))?.level, .unknown)
    }

    func testSoundAndMicrophone() {
        let missing = items("status=none", audio: [])
        XCTAssertEqual(missing.map(\.id), ["quest", "alvr", "sound"])
        XCTAssertEqual(item("sound", in: missing)?.fix, .installBlackHole)
        XCTAssertTrue(item("sound", in: missing)?.detail.contains(PlayReadiness.blackHoleCommand) ?? false)
        let wrongRate = items("status=none",
                              audio: [GameAudioDevice(id: 1, name: "BlackHole 2ch", sampleRate: 44_100)])
        XCTAssertEqual(item("sound", in: wrongRate)?.fix, .openAudioMIDISetup)
        XCTAssertEqual(item("microphone", in: items("status=none", microphone: .notDetermined))?.fix,
                       .askMicrophone)
        XCTAssertEqual(item("microphone", in: items("status=none", microphone: .denied))?.fix,
                       .openMicrophoneSettings)
        XCTAssertNil(item("microphone", in: items("status=none", microphone: .restricted))?.fix)
        // Only the exact device play.zsh routes to counts.
        let other = items("status=none",
                          audio: [GameAudioDevice(id: 2, name: "BlackHole 16ch", sampleRate: 48_000)])
        XCTAssertEqual(item("sound", in: other)?.fix, .installBlackHole)
    }
}

final class AppBundleEnvironmentTests: XCTestCase {
    func testCheckoutLinkedBundle() throws {
        let root = try temporaryDirectory()
        let checkout = root.appendingPathComponent("BasaltVR", isDirectory: true)
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent("streamer"), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: checkout.appendingPathComponent("streamer/Package.swift").path, contents: Data())
        let app = root.appendingPathComponent("BasaltVR.app", isDirectory: true)
        let overrides = AppBundleEnvironment.overrides(
            bundleURL: app, infoDictionary: ["BasaltRepoRoot": checkout.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        XCTAssertEqual(overrides["BASALT_REPO_ROOT"], checkout.path)
        XCTAssertEqual(overrides["PATH"],
                       "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
    }

    func testPackagedSupportFolderWins() throws {
        let app = try temporaryDirectory().appendingPathComponent("BasaltVR.app", isDirectory: true)
        let support = app.appendingPathComponent("Contents/Resources/BasaltVR", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: support.appendingPathComponent("BasaltVR.support.json").path, contents: Data())
        XCTAssertEqual(AppBundleEnvironment.overrides(
            bundleURL: app, infoDictionary: ["BasaltRepoRoot": "/elsewhere"],
            environment: [:])["BASALT_REPO_ROOT"], support.path)
    }

    func testShellChoiceAndPlainExecutablesAreLeftAlone() throws {
        let app = try temporaryDirectory().appendingPathComponent("BasaltVR.app", isDirectory: true)
        let fullPath = PlayLaunchPlan.searchPath(nil)
        XCTAssertEqual(AppBundleEnvironment.overrides(
            bundleURL: app, infoDictionary: ["BasaltRepoRoot": "/x"],
            environment: ["BASALT_REPO_ROOT": "/mine", "PATH": fullPath]), [:])
        XCTAssertNil(AppBundleEnvironment.overrides(
            bundleURL: URL(fileURLWithPath: "/repo/streamer/.build/release"),
            infoDictionary: [:], environment: ["PATH": fullPath])["BASALT_REPO_ROOT"])
        // A checkout that no longer exists is not used.
        XCTAssertNil(AppBundleEnvironment.overrides(
            bundleURL: app, infoDictionary: ["BasaltRepoRoot": "/no/such/checkout"],
            environment: ["PATH": fullPath])["BASALT_REPO_ROOT"])
    }
}
