import XCTest
@testable import BasaltManagerKit
import BasaltBottleKit
import BasaltCore

final class DiagnosticsTests: XCTestCase {
    private let redactor = DiagnosticRedactor(homeDirectory: "/Users/ada/", userName: "ada")

    func testRedactsHomeFolderAndWineUserPaths() {
        XCTAssertEqual(
            redactor.redact("/Users/ada/Library/Application Support/BasaltVR/Bottles/vr/prefix"),
            "~/Library/Application Support/BasaltVR/Bottles/vr/prefix")
        XCTAssertEqual(redactor.redact("cd /Users/ada"), "cd ~")
        XCTAssertEqual(
            redactor.redact(#"C:\users\ada\AppData\Local\Programs\bs-manager"#),
            #"C:\users\<user>\AppData\Local\Programs\bs-manager"#)
        XCTAssertEqual(
            redactor.redact("prefix/drive_c/users/Ada/Documents"),
            "prefix/drive_c/users/<user>/Documents")
        // JSON escapes Windows backslashes.
        XCTAssertEqual(
            redactor.redact(#""C:\\users\\ada\\AppData""#),
            #""C:\\users\\<user>\\AppData""#)
        // Only whole path components are names.
        XCTAssertEqual(redactor.redact("/Users/adam/file"), "/Users/adam/file")
        XCTAssertEqual(redactor.redact("drive_c/users/adam"), "drive_c/users/adam")
    }

    func testRedactsNetworkAndDeviceIdentifiers() {
        let line = "ALVR headset '4242.client.alvr' announced itself from 192.168.1.37 "
            + "(fe80::1c2b:3aff:fe4d:5e6f%en0, aa:bb:cc:dd:ee:ff)"
        XCTAssertEqual(
            redactor.redact(line),
            "ALVR headset '<headset>.client.alvr' announced itself from <ipv4> "
                + "(<ipv6>, <mac>)")
        XCTAssertEqual(
            redactor.redact("USB Quest TESTQUEST00042 is authorized; adb control/video forwards are ready."),
            "USB Quest <serial> is authorized; adb control/video forwards are ready.")
        XCTAssertEqual(
            redactor.redact("adb-TESTQUEST00042-AbCdEf._adb-tls-connect._tcp"),
            "adb-<serial>-AbCdEf._adb-tls-connect._tcp")
        XCTAssertEqual(redactor.redact("Adas-MacBook-Pro.local:9943"), "<host>.local:9943")
        XCTAssertEqual(redactor.redact("mail ada@example.com now"), "mail <email> now")
        XCTAssertEqual(redactor.redact("owner 76561198012345678"), "owner <steamid>")
        XCTAssertEqual(
            redactor.redact("token 0123456789abcdef0123456789abcdef ok"), "token <token> ok")
        XCTAssertEqual(redactor.redact(#"AccountName="ada_plays" ok"#), #"AccountName="<redacted>" ok"#)
        XCTAssertEqual(redactor.redact("serial: R3CN90ABCDE"), "serial: <redacted>")
        // Inside rendered JSON: the string's own closing quote, escaped
        // quotes, and escape sequences survive.
        XCTAssertEqual(redactor.redact(#"["account=ada"]"#), #"["account=<redacted>"]"#)
        XCTAssertEqual(redactor.redact(#""login=\"ada\" ok""#), #""login=\"<redacted>\" ok""#)
        XCTAssertEqual(redactor.redact(#""username=ada\nnext""#), #""username=<redacted>\nnext""#)
        XCTAssertEqual(redactor.redact(#""login=CORP\\ada""#), #""login=<redacted>""#)
    }

    func testKeepsOrdinaryDiagnosticText() {
        let lines = [
            "  Quest 72.0 fps, input→display latency: 51.2 ms",
            "  video send: 28.4 Mbps on wire",
            "listening on 127.0.0.1:9944 and 0.0.0.0",
            "loopback ::1 only",
            "12:34:56.789 frame 42",
            "Wine 11.10 with DXMT v0.80-basalt.1 at /usr/local/bin and /opt/homebrew/bin",
            "1344 × 1408 BGRA swapchain, DXGI_FORMAT_B8G8R8A8_UNORM, H264",
            "std::vector and BasaltCore::RuntimeLink",
            "/var/folders/xy/T/basalt-manager-3F2504E0-4F89-11D3-9A0C-0305E82C3301.control",
            "commit 2e8f775c1a2b",
        ]
        for line in lines {
            XCTAssertEqual(redactor.redact(line), line)
        }
    }

    func testReportRendersRedactedMarkdownAndValidJSON() throws {
        let report = makeReport(log: """
            Preparing beat-saber…
            \u{1B}[32mUSB Quest TESTQUEST00042 is authorized\u{1B}[0m
            game: loading C:\\users\\ada\\AppData\\Roaming\\Beat Saber
            ```nested fence```
            account=player_one
            steam: login="player_two" ok

            """)

        let markdown = report.markdown(redactedWith: redactor)
        XCTAssertTrue(markdown.contains("## BasaltVR diagnostic report"))
        XCTAssertTrue(markdown.contains("control protocol v\(RuntimeLink.protocolVersion)"))
        XCTAssertTrue(markdown.contains("- [x] **OpenXR runtime** — ~/BasaltVR/runtime/build/bin/basalt_openxr.dll"))
        XCTAssertTrue(markdown.contains("- [ ] **Android Platform Tools** (optional)"))
        XCTAssertTrue(markdown.contains("| vr | managed | pinned-wine | yes | no |"))
        XCTAssertTrue(markdown.contains("| beat-saber-vr | vr | steam |"))
        XCTAssertTrue(markdown.contains("| custom |"))
        XCTAssertTrue(markdown.contains("- beat-saber-vr: Wireless (Wi-Fi) · 90 fps"))
        XCTAssertTrue(markdown.contains("failed: Steam is open but not signed in."))
        XCTAssertTrue(markdown.contains("````text"), "fence must outlast the log's own backticks")
        XCTAssertTrue(markdown.contains("USB Quest <serial> is authorized"))
        XCTAssertFalse(markdown.contains("\u{1B}"))
        for leaked in ["/Users/ada", #"\ada"#, "users/ada"] {
            XCTAssertFalse(markdown.contains(leaked), markdown)
        }
        XCTAssertFalse(markdown.contains("TESTQUEST00042"))

        let json = try report.json(redactedWith: redactor)
        for leaked in ["/Users/ada", #"\\ada"#, "player_one", "player_two"] {
            XCTAssertFalse(json.contains(leaked), json)
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, DiagnosticReport.currentFormatVersion)
        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.first?["environmentKeys"] as? [String], ["SteamAppId"])
        XCTAssertNil(profiles.first?["environment"], "environment values are never exported")
        let sessions = try XCTUnwrap(object["recentSessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
    }

    func testReportCanLeaveOutTheLog() {
        let markdown = makeReport(log: nil).markdown(redactedWith: redactor)
        XCTAssertTrue(markdown.contains("### Session log\n\nNot included."))
    }

    func testLogTailKeepsTheLastLines() {
        let log = (1...(DiagnosticReport.maximumLogLines + 25)).map { "line \($0)" }
            .joined(separator: "\n") + "\n\n"
        let tail = DiagnosticReport.tail(of: log)
        XCTAssertEqual(tail.count, DiagnosticReport.maximumLogLines)
        XCTAssertEqual(tail.first, "line 26")
        XCTAssertEqual(tail.last, "line \(DiagnosticReport.maximumLogLines + 25)")
    }

    func testSourceRevisionReadsLooseAndPackedReferences() throws {
        let repository = try temporaryDirectory()
        let git = repository.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        let loose = String(repeating: "a1", count: 20)
        let packed = String(repeating: "b2", count: 20)

        try "ref: refs/heads/main\n".write(
            to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try (loose + "\n").write(
            to: git.appendingPathComponent("refs/heads/main"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SourceRevision.read(repository: repository), String(loose.prefix(12)))

        try FileManager.default.removeItem(at: git.appendingPathComponent("refs/heads/main"))
        try "# pack-refs with: peeled\n\(packed) refs/heads/main\n".write(
            to: git.appendingPathComponent("packed-refs"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SourceRevision.read(repository: repository), String(packed.prefix(12)))

        try (loose + "\n").write(
            to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SourceRevision.read(repository: repository, length: 7), String(loose.prefix(7)))

        XCTAssertNil(SourceRevision.read(repository: repository.appendingPathComponent("missing")))
    }

    func testSourceRevisionFollowsWorktreeLinks() throws {
        let root = try temporaryDirectory()
        let common = root.appendingPathComponent("main/.git", isDirectory: true)
        let linked = common.appendingPathComponent("worktrees/feature", isDirectory: true)
        let checkout = root.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(
            at: common.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let sha = String(repeating: "c3", count: 20)
        try "gitdir: \(linked.path)\n".write(
            to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature\n".write(
            to: linked.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(
            to: linked.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try sha.write(
            to: common.appendingPathComponent("refs/heads/feature"), atomically: true, encoding: .utf8)

        XCTAssertEqual(SourceRevision.read(repository: checkout), String(sha.prefix(12)))
    }

    private func makeReport(log: String?) -> DiagnosticReport {
        let engineRoot = URL(fileURLWithPath: "/Users/ada/BasaltVR/runtime/build/wine")
        let engine = BottleEngine(
            id: "pinned-wine", kind: .pinned,
            wineBinary: engineRoot.appendingPathComponent("bin/wine"),
            wineserverBinary: engineRoot.appendingPathComponent("bin/wineserver"),
            root: engineRoot, supportsBasaltDXMT: true)
        var managed = ManagedBottle(
            name: "vr", engine: engine,
            prefix: URL(fileURLWithPath: "/Users/ada/Library/Application Support/BasaltVR/Bottles/vr/prefix"),
            engineRoot: engineRoot, wineBinary: engine.wineBinary)
        managed.dxmtInstalled = true
        let bottle = DiscoveredBottle(
            name: "vr", origin: .managed,
            prefix: URL(fileURLWithPath: managed.prefixPath), managed: managed)
        let profile = LaunchProfile(
            name: "beat-saber-vr", bottleName: "vr", source: .steam,
            executable: #"C:\Program Files (x86)\Steam\steam.exe"#,
            arguments: ["-applaunch", "620980"],
            environment: ["SteamAppId": "620980"])
        var custom = StreamLaunchSettings()
        custom.connection = .wifi
        custom.fps = 90
        var failed = SessionRecord(
            profileName: "beat-saber-vr", settings: custom,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        failed.endedAt = failed.startedAt.addingTimeInterval(30)
        failed.outcome = .failed
        failed.failureReason = "Steam is open but not signed in."

        return DiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_100),
            application: .init(version: "0.1.0", build: "1", sourceRevision: "2e8f775c1a2b"),
            system: .init(
                operatingSystem: "macOS 26.0 (Build 25A1)", hardwareModel: "Mac15,8",
                chip: "Apple M3 Max", architecture: "arm64", memoryGigabytes: 36,
                processorCount: 14, thermalState: "nominal", lowPowerMode: false),
            setupChecks: [
                SetupCheck(id: "runtime", title: "OpenXR runtime",
                           detail: "/Users/ada/BasaltVR/runtime/build/bin/basalt_openxr.dll",
                           status: .ready, required: true),
                SetupCheck(id: "adb", title: "Android Platform Tools",
                           detail: "Optional for wireless", status: .actionNeeded,
                           required: false),
            ],
            engines: [engine],
            bottles: [bottle],
            profiles: [profile],
            defaultStreamSettings: StreamLaunchSettings(),
            profileStreamSettings: ["beat-saber-vr": custom],
            currentSession: .init(state: "stopped"),
            recentSessions: [failed],
            log: log)
    }
}
