import Foundation
import XCTest
import Darwin
@testable import BasaltManagerKit

/// Runs the real scripts/play.zsh through PlaySessionRunner, with a fake adb, a fake
/// streamer, a fake basaltctl, and a fake steam.zsh in a private folder. Nothing real is
/// touched: no headset, no Steam, no Wine, no /tmp/basalt-control, no real logs.
final class PlaySessionRunnerTests: XCTestCase {
    private var work: URL!
    private var tools: PlayTools!

    private static let usbLine =
        "QUEST3SERIAL01         device usb:1-1 product:eureka model:Quest_3 device:eureka transport_id:2"

    override func setUpWithError() throws {
        work = try temporaryDirectory()
        let repoScripts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts", isDirectory: true)
        let scripts = work.appendingPathComponent("scripts", isDirectory: true)
        for folder in ["scripts", "bin", "fakebin", "home", "data"] {
            try FileManager.default.createDirectory(
                at: work.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in ["play.zsh", "quest-adb.zsh", "game-processes.zsh"] {
            try FileManager.default.copyItem(
                at: repoScripts.appendingPathComponent(name),
                to: scripts.appendingPathComponent(name))
        }
        try write("scripts/steam.zsh", """
            #!/bin/zsh
            print -r -- "$1" >>"$FAKE_STEAM_LOG"
            exit 0
            """)
        try write("bin/adb", """
            #!/bin/zsh
            print -r -- "adb $*" >>"$FAKE_ADB_LOG"
            if [[ $1 == devices ]]; then
                print "List of devices attached"
                [[ -n ${FAKE_DEVICES:-} ]] && print -r -- "$FAKE_DEVICES"
                exit 0
            fi
            [[ $1 == -s ]] && shift 2
            case $1 in
                get-state) print device ;;
                shell) [[ $2 == pm ]] && print "package:alvr.client.stable" ;;
                logcat)
                    print $$ >"$FAKE_ADB_LOG.logcat_pid"
                    trap 'kill $sp 2>/dev/null; exit 0' TERM
                    sleep 300 & sp=$!
                    wait ;;
            esac
            exit 0
            """)
        // No other streamer runs; Steam's web helper is "up"; the bottle is down.
        try write("bin/pgrep", """
            #!/bin/zsh
            for a in "$@"; do [[ $a == *steamwebhelper* ]] && exit 0; done
            exit 1
            """)
        try write("fakebin/basalt-streamer", """
            #!/bin/zsh
            [[ $1 == --list-audio-devices ]] && exit 0
            print -r -- "$*" >>"$FAKE_STREAMER_LOG"
            print $$ >"$FAKE_STREAMER_LOG.pid"
            args=("$@")
            print "9999 token 2304 1216" >"${args[$args[(i)--runtime]+1]}"
            print "ALVR control accepted by 'Quest 3': StreamConfig sent"
            trap 'print "Restored the previous Mac audio output"; exit 0' TERM
            n=0
            while :; do
                sleep 0.2
                (( n++ ))
                if (( n == 8 )); then
                    print "OpenXR runtime connected (session 1, d3d11)"
                    print "  Quest 71.6 fps; input→display latency: 68.2 ms average, 90.0 ms max (decode 10.0, decoder queue 1.0, vsync 2.0 ms)"
                fi
            done
            """)
        try write("fakebin/basaltctl", """
            #!/bin/zsh
            case $1 in
                profile)
                    if [[ $3 == long ]]; then
                        print -r -- '{"bottleName":"fake","source":"steam","executable":"C:\\\\Games\\\\Long\\\\long.exe","arguments":[]}'
                    else
                        print -r -- '{"bottleName":"fake","source":"native","executable":"game.exe","arguments":[]}'
                    fi ;;
                run)
                    if [[ $2 == long ]]; then
                        print $$ >"$FAKE_GAME_PID"
                        trap 'kill $sp 2>/dev/null; exit 0' TERM
                        sleep 300 & sp=$!
                        wait
                    else
                        sleep ${FAKE_GAME_SECONDS:-2}
                    fi ;;
            esac
            exit 0
            """)
        tools = PlayTools(repoRoot: work, binDirectory: work.appendingPathComponent("fakebin"))
    }

    private func write(_ path: String, _ text: String) throws {
        let url = work.appendingPathComponent(path)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func path(_ name: String) -> String { work.appendingPathComponent(name).path }

    private func environment(devices: String) -> [String: String] {
        [
            "FAKE_GAME_SECONDS": "3",
            "PATH": path("bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": path("home"),
            "TMPDIR": NSTemporaryDirectory(),
            "BASALT_PLAY_CONTROL": path("control"),
            "BASALT_ALVR_STOP_WAIT": "0",
            "BASALT_ALVR_START_WAIT": "0",
            "BASALT_PICK_DELAY": "0",
            "BASALT_STEAM_SETTLE": "0",
            "BASALT_PARENT_POLL": "0.2",
            // The app's choice must win over these.
            "BASALT_WIFI_MBPS": "25",
            "BASALT_CODEC": "h264",
            "FAKE_DEVICES": devices,
            "FAKE_ADB_LOG": path("adb.log"),
            "FAKE_STEAM_LOG": path("steam.log"),
            "FAKE_STREAMER_LOG": path("streamer.log"),
            "FAKE_GAME_PID": path("game.pid"),
        ]
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items = [PlaySessionRunner.Output]()
        func add(_ output: PlaySessionRunner.Output) {
            lock.lock(); items.append(output); lock.unlock()
        }
        var outputs: [PlaySessionRunner.Output] {
            lock.lock(); defer { lock.unlock() }; return items
        }
        var events: [PlayEvent] {
            outputs.compactMap { if case .event(let event) = $0 { return event } else { return nil } }
        }
        var exitStatus: Int32? {
            outputs.lazy.compactMap { if case .exited(let s) = $0 { return s } else { return nil } }.first
        }
    }

    private func start(_ profile: String, _ options: PlayOptions, devices: String = usbLine,
                       extra: [String: String] = [:]) throws -> (PlaySessionRunner, Recorder) {
        let recorder = Recorder()
        let plan = PlayLaunchPlan.make(
            profile: profile, options: options, tools: tools,
            dataRoot: work.appendingPathComponent("data"), parentPID: getpid())
        let runner = PlaySessionRunner(
            plan: plan,
            baseEnvironment: environment(devices: devices).merging(extra) { $1 }
        ) { recorder.add($0) }
        try runner.start()
        return (runner, recorder)
    }

    private func wait(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func alive(_ pidFile: String) -> Bool {
        guard let text = try? String(contentsOfFile: path(pidFile), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return kill(pid, 0) == 0
    }

    private func streamerArguments() -> String {
        ((try? String(contentsOfFile: path("streamer.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").first.map(String.init) ?? ""
    }

    func testFullSessionDrivesThePlainLanguageStatus() throws {
        let (_, recorder) = try start("beat-saber-steam", PlayOptions(transport: .auto, quality: .high))
        XCTAssertTrue(wait { recorder.exitStatus != nil }, "\(recorder.outputs)")
        XCTAssertEqual(recorder.exitStatus, 0, "\(recorder.outputs)")

        var progress = PlayProgress()
        var stats = PlayLiveStats()
        progress.begin(gameTitle: "Beat Saber")
        var sawPlaying = false
        for output in recorder.outputs {
            switch output {
            case .event(let event): progress.apply(event)
            case .streamerLine(let line):
                stats.apply(streamerLine: line)
                progress.apply(streamerLine: line)
            case .exited(let status): progress.finish(exitStatus: status, lastError: nil)
            case .line: break
            }
            if progress.phase == .playing { sawPlaying = true }
        }
        let events = recorder.events
        XCTAssertEqual(events.first, .start(profile: "beat-saber-steam"))
        XCTAssertTrue(events.contains(.connection(.usb)))
        XCTAssertTrue(events.contains(.alvrRestart))
        XCTAssertTrue(events.contains(.headsetReady))
        XCTAssertTrue(events.contains(.gameStart(profile: "beat-saber-steam")))
        XCTAssertEqual(events.suffix(3), [.gameEnded(status: 0), .stopping, .stopped])
        XCTAssertTrue(sawPlaying, "the runtime connected line moves the status to Playing")
        XCTAssertEqual(progress.phase, .finished)
        XCTAssertEqual(progress.headline, "The game ended")
        XCTAssertEqual(stats.framesPerSecond ?? 0, 71.6, accuracy: 0.01)
        XCTAssertEqual(stats.latencyMilliseconds ?? 0, 68.2, accuracy: 0.01)
        XCTAssertTrue(progress.streamerLog?.path.hasPrefix(path("home")) ?? false)
        XCTAssertFalse(alive("streamer.log.pid"))
        XCTAssertFalse(alive("adb.log.logcat_pid"))
    }

    /// The play.zsh matrix through the app: transport × quality → the streamer's codec,
    /// link, and bitrate. Shell variables (BASALT_WIFI_MBPS=25, BASALT_CODEC=h264) lose.
    func testTransportAndQualityReachTheStreamer() throws {
        let cases: [(PlayTransport, PlayQuality, String, String, String?)] = [
            (.usb, .high, Self.usbLine,
             "--codec hevc --wired --profile m3pro --resolution quality --mbps 60", nil),
            (.usb, .normal, Self.usbLine, "--codec hevc --wired --profile m3pro", "--resolution"),
            (.wifi, .high, Self.usbLine, "--codec hevc --wireless --resolution quality --mbps 50", nil),
            (.wifi, .normal, Self.usbLine, "--codec h264 --wireless --mbps 20", "--resolution"),
            (.auto, .high, Self.usbLine,
             "--codec hevc --wired --profile m3pro --resolution quality --mbps 60", nil),
            (.auto, .high, "", "--codec hevc --wireless --resolution quality --mbps 50", nil),
            (.auto, .normal, "", "--codec h264 --wireless --mbps 20", nil),
        ]
        for (transport, quality, devices, expected, absent) in cases {
            try? FileManager.default.removeItem(atPath: path("streamer.log"))
            let (_, recorder) = try start(
                "beat-saber-steam", PlayOptions(transport: transport, quality: quality),
                devices: devices, extra: ["FAKE_GAME_SECONDS": "0.3"])
            let name = "\(transport) \(quality) devices=\(devices.isEmpty ? "none" : "usb")"
            XCTAssertTrue(wait { recorder.exitStatus != nil }, name)
            XCTAssertEqual(recorder.exitStatus, 0, "\(name): \(recorder.outputs)")
            let arguments = streamerArguments()
            XCTAssertTrue(arguments.hasSuffix(expected), "\(name): \(arguments)")
            if let absent { XCTAssertFalse(arguments.contains(absent), "\(name): \(arguments)") }
            XCTAssertTrue(recorder.events.contains(
                .connection(arguments.contains("--wired") ? .usb : .wifi)), name)
        }
    }

    func testUSBWithoutAQuestFailsInPlainLanguage() throws {
        let (_, recorder) = try start(
            "beat-saber-steam", PlayOptions(transport: .usb, quality: .high), devices: "")
        XCTAssertTrue(wait { recorder.exitStatus != nil })
        XCTAssertEqual(recorder.exitStatus, 1)
        XCTAssertTrue(recorder.events.contains(.fail(.noUSBQuest)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("streamer.log")),
                       "no streamer without a Quest")
    }

    /// Stop while the game runs: play.zsh closes the game, Steam, the streamer, and the
    /// Quest log, then exits; nothing is left behind.
    func testStopCleansUpEverything() throws {
        let (runner, recorder) = try start("long", PlayOptions(transport: .usb, quality: .high))
        XCTAssertTrue(wait { recorder.events.contains(.gameStart(profile: "long")) && self.alive("game.pid") },
                      "\(recorder.outputs)")
        XCTAssertTrue(alive("streamer.log.pid"))
        XCTAssertTrue(alive("adb.log.logcat_pid"))
        XCTAssertTrue(runner.isRunning)

        runner.stop()
        XCTAssertTrue(wait(timeout: 20) { recorder.exitStatus != nil }, "\(recorder.outputs)")
        XCTAssertEqual(recorder.exitStatus, 130)
        XCTAssertFalse(runner.isRunning)
        XCTAssertTrue(wait(timeout: 3) {
            !self.alive("game.pid") && !self.alive("streamer.log.pid") && !self.alive("adb.log.logcat_pid")
        })
        let steam = (try? String(contentsOfFile: path("steam.log"), encoding: .utf8)) ?? ""
        XCTAssertEqual(steam.split(separator: "\n"), ["stop", "start", "stop"],
                       "old Steam closed, Steam started for the game, Steam closed on Stop")
        XCTAssertTrue(recorder.events.suffix(2).elementsEqual([.stopping, .stopped]))
        let human = recorder.outputs.compactMap { output -> String? in
            if case .line(let text, _) = output { return text } else { return nil }
        }
        XCTAssertTrue(human.contains("Mac sound output is back to normal."), "\(human)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("control")))
        if case .exited = recorder.outputs.last {} else { XCTFail("exited must be last") }
    }

    func testStopAfterExitIsHarmless() throws {
        let (runner, recorder) = try start(
            "beat-saber-steam", PlayOptions(transport: .usb), extra: ["FAKE_GAME_SECONDS": "0.3"])
        XCTAssertTrue(wait { recorder.exitStatus != nil })
        runner.stop()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(recorder.outputs.filter {
            if case .exited = $0 { return true } else { return false }
        }.count, 1)
    }
}
