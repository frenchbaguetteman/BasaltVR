import XCTest
@testable import BasaltBottleKit

final class WineProcessesTests: XCTestCase {
    private let prefix = "/Data/Bottles/pcvr/prefix"
    private let engine = "/Data/Bottles/pcvr/engine"
    private let server = "/private/tmp/.wine-501/server-1000011-4966654"

    /// `lsof -F pn` output for the processes seen after a Library Stop.
    private var lsofOutput: String {
        """
        p54684
        n\(prefix)/drive_c/windows/system32
        n\(engine)/lib/wine/x86_64-unix/wine
        n\(server)/tmpmap-7742dfa7
        p54712
        n\(prefix)/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64
        n\(engine)/lib/wine/x86_64-unix/ntdll.so
        p66846
        n\(server)
        n\(engine)/bin/wineserver
        p86055
        n/System/Library/Frameworks/CoreServices.framework/mdworker_shared
        n\(prefix)/drive_c/Program Files (x86)/Steam/logs/bootstrap_log.txt
        p91501
        n\(prefix)/drive_c/Program Files (x86)/Steam
        n/bin/bash
        p70000
        n/Users/me/Library/Application Support/CrossOver/Bottles/Steam/drive_c/windows
        n/private/tmp/.wine-501/server-1000011-5000000/tmpmap-1
        n\(engine)/lib/wine/x86_64-unix/wine
        p40598
        n\(server)/tmpmap-1
        p1
        n\(server)/tmpmap-2
        p77777
        n\(prefix)-old/drive_c/windows
        n\(engine)/lib/wine/x86_64-unix/wine
        """
    }

    func testOwnershipMatchesOnlyThisPrefixsWineProcesses() {
        let pids = WineProcessOwnership.processIDs(
            lsofOutput: lsofOutput, prefix: prefix, engineRoot: engine,
            serverDirectories: [server], excluding: [40598])

        // explorer.exe (server mapping), a CEF helper that has not mapped the
        // server yet (prefix handle + engine), and the wineserver itself.
        // Not: Spotlight or a shell inside the prefix, a CrossOver bottle on the
        // same engine, BasaltVR itself, launchd, or a sibling folder.
        XCTAssertEqual(pids, [54684, 54712, 66846])
    }

    func testServerDirectoryUsesThePrefixDeviceAndInodeInHex() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltServerDirectory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: prefix) }
        var status = stat()
        XCTAssertEqual(stat(prefix.path, &status), 0)
        let name = "server-\(String(UInt64(UInt32(bitPattern: status.st_dev)), radix: 16))"
            + "-\(String(UInt64(status.st_ino), radix: 16))"

        XCTAssertEqual(
            WineProcessOwnership.serverDirectories(prefix: prefix, userID: 501),
            ["/tmp/.wine-501/\(name)", "/private/tmp/.wine-501/\(name)"])
        XCTAssertEqual(WineProcessOwnership.serverDirectories(
            prefix: prefix.appendingPathComponent("missing")), [])
    }

    func testSteamClientImageMatchesOnlySteamExe() {
        XCTAssertTrue(WineProcessOwnership.isSteamClient(
            #"C:\Program Files (x86)\Steam\steam.exe -inhibitbootstrap"#))
        XCTAssertTrue(WineProcessOwnership.isSteamClient("steam.exe"))
        XCTAssertFalse(WineProcessOwnership.isSteamClient(
            #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe -steampath=C:\Program Files (x86)\Steam\steam.exe"#))
        XCTAssertFalse(WineProcessOwnership.isSteamClient("/usr/bin/steam"))
    }

    func testCleanupTerminatesWineProcessesLeftWithoutAServer() throws {
        let fixture = try Fixture(wineserverScript: "exit 1\n")
        addTeardownBlock { fixture.remove() }
        let control = FakeProcessControl(
            lsof: fixture.lsof([
                (101, "\(fixture.server)/tmpmap-1"),
                (102, "\(fixture.server)/tmpmap-2"),
                (200, "\(fixture.prefix.path)/drive_c/Program Files (x86)/Steam/logs/x.txt"),
                (300, "/private/tmp/.wine-501/server-1-2/tmpmap-3"),
            ]),
            surviveTerm: [102])
        let manager = fixture.manager(control: control)

        // No wineserver answers --kill (it crashed), yet the bottle ends empty.
        XCTAssertEqual(
            try manager.terminateBottleProcesses(launchedWith: fixture.command),
            CommandOutput(status: 0, output: ""))

        XCTAssertEqual(control.signals, [
            .init(signal: SIGTERM, pid: 101), .init(signal: SIGTERM, pid: 102),
            .init(signal: SIGKILL, pid: 102),
        ])
        XCTAssertEqual(control.running, [200, 300])
    }

    func testShutdownAsksSteamToCloseBeforeStoppingWine() throws {
        let fixture = try Fixture(wineserverScript: "exit 1\n")
        addTeardownBlock { fixture.remove() }
        let steam = fixture.prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steam.exe")
        try FileManager.default.createDirectory(
            at: steam.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: steam)
        let control = FakeProcessControl(
            lsof: fixture.lsof([(101, "\(fixture.server)/tmpmap-1")]),
            commands: [
                101: #"C:\Program Files (x86)\Steam\steam.exe -inhibitbootstrap"#,
                102: #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe"#,
                103: #"C:\Program Files (x86)\Steam\steam.exe"#,
            ],
            serverRunning: true)
        // Steam closes, then Wine ends its services and the server exits.
        control.onPause = { control.serverRunning = false; control.running = [] }
        let manager = fixture.manager(control: control)

        let report = try manager.shutDownBottle(launchedWith: fixture.command)

        XCTAssertTrue(report.steamClosedGracefully)
        XCTAssertEqual(report.leftoverProcessIDs, [])
        XCTAssertEqual(try String(contentsOf: fixture.wineLog, encoding: .utf8),
                       #"C:\Program Files (x86)\Steam\steam.exe|-shutdown"# + "\n")
        // Only pid 101 was confirmed to belong to the bottle by its files.
        XCTAssertEqual(control.openFilesRequests, [[101, 103], nil])
        XCTAssertEqual(control.signals, [])
    }

    func testShutdownDoesNotStartSteamWhenItIsNotRunning() throws {
        let fixture = try Fixture(wineserverScript: "exit 1\n")
        addTeardownBlock { fixture.remove() }
        let control = FakeProcessControl(
            lsof: "", commands: [7: #"C:\windows\system32\services.exe"#],
            serverRunning: true)
        let manager = fixture.manager(control: control)

        let report = try manager.shutDownBottle(launchedWith: fixture.command)

        XCTAssertFalse(report.steamClosedGracefully)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.wineLog.path))
    }

    func testRunnerTimeoutEndsAHungCommand() throws {
        let started = Date()
        let result = try ProcessBottleCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
            environment: [:], currentDirectory: nil, timeout: 0.3)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}

private struct Fixture {
    let root: URL
    let prefix: URL
    let wine: URL
    let wineLog: URL
    let server: String

    init(wineserverScript: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltWineProcesses-\(UUID().uuidString)", isDirectory: true)
        prefix = root.appendingPathComponent("prefix", isDirectory: true)
        let bin = root.appendingPathComponent("engine/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        wine = bin.appendingPathComponent("wine")
        wineLog = root.appendingPathComponent("wine.log")
        try Data("#!/bin/sh\nprintf '%s|%s\\n' \"$1\" \"$2\" >> '\(wineLog.path)'\n".utf8)
            .write(to: wine)
        let wineserver = bin.appendingPathComponent("wineserver")
        try Data(("#!/bin/sh\n" + wineserverScript).utf8).write(to: wineserver)
        for executable in [wine, wineserver] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        server = try XCTUnwrap(WineProcessOwnership.serverDirectories(prefix: prefix).last)
    }

    var command: BottleLaunchCommand {
        BottleLaunchCommand(
            executable: wine, arguments: [],
            environment: ["WINEPREFIX": prefix.path], currentDirectory: nil)
    }

    func manager(control: FakeProcessControl) -> BottleManager {
        BottleManager(
            root: root.appendingPathComponent("data"), repoRoot: root,
            processControl: control)
    }

    func lsof(_ files: [(Int32, String)]) -> String {
        files.map { "p\($0.0)\nn\($0.1)\n" }.joined()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class FakeProcessControl: WineProcessControlling, @unchecked Sendable {
    struct Signal: Equatable {
        let signal: Int32
        let pid: Int32
    }

    let lsof: String
    let commands: [Int32: String]
    let surviveTerm: Set<Int32>
    var serverRunning: Bool
    var running: Set<Int32>
    var signals = [Signal]()
    var openFilesRequests = [[Int32]?]()
    var onPause: (() -> Void)?

    init(lsof: String, commands: [Int32: String] = [:], surviveTerm: Set<Int32> = [],
         serverRunning: Bool = false) {
        self.lsof = lsof
        self.commands = commands
        self.surviveTerm = surviveTerm
        self.serverRunning = serverRunning
        running = Set(lsof.split(separator: "\n").compactMap {
            $0.hasPrefix("p") ? Int32($0.dropFirst()) : nil
        })
    }

    func openFiles(processIDs: [Int32]?) -> String {
        openFilesRequests.append(processIDs)
        // After the shutdown, only processes that are still running remain.
        return lsof.split(separator: "\n").reduce(into: (text: "", keep: false)) { state, line in
            if line.hasPrefix("p") {
                let pid = Int32(line.dropFirst()) ?? 0
                state.keep = running.contains(pid)
                    && (processIDs.map { $0.contains(pid) } ?? true)
            }
            if state.keep { state.text += line + "\n" }
        }.text
    }

    func commandLines() -> [Int32: String] { commands }

    func send(_ signal: Int32, to processID: Int32) {
        signals.append(Signal(signal: signal, pid: processID))
        if signal == SIGKILL || !surviveTerm.contains(processID) {
            running.remove(processID)
        }
    }

    func isRunning(_ processID: Int32) -> Bool { running.contains(processID) }

    func isServerRunning(serverDirectory: String) -> Bool { serverRunning }

    func pause(_ seconds: TimeInterval) { onPause?() }
}
