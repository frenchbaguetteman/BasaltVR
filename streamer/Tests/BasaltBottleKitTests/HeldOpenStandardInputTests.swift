import XCTest
import Darwin
@testable import BasaltBottleKit

/// Khronos hello_xr quits when its stdin reaches end of file, so a game must get a stdin
/// that stays open (and empty) while it runs, not /dev/null.
final class HeldOpenStandardInputTests: XCTestCase {
    func testChildStdinStaysOpenUntilClosedAndTheChildHoldsNoWriteEnd() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"read x; echo "eof:$x""#]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let input = try HeldOpenStandardInput.run(process)
        addTeardownBlock { if process.isRunning { process.terminate() } }

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(process.isRunning, "stdin reached EOF while the launcher held it open")

        // If the child had inherited the write end, `read` would never see EOF.
        input.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(process.isRunning, "the child did not see EOF after close()")
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(),
                          as: UTF8.self)
        XCTAssertEqual(text, "eof:\n")
    }

    func testPipeIsReleasedWhenTheChildExits() throws {
        let baseline = Self.openDescriptors()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let input = try HeldOpenStandardInput.run(process)
        process.waitUntilExit()

        // The exit source closes the write end on its own queue.
        let deadline = Date().addingTimeInterval(2)
        while input.isOpen && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(input.isOpen)
        XCTAssertEqual(Self.openDescriptors().subtracting(baseline), [])
    }

    func testProcessRunnerGivesTheChildAnOpenEmptyStdin() throws {
        let result = try ProcessBottleCommandRunner().runKeepingInputOpen(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "[ -p /dev/stdin ] && echo pipe; " + Self.stdinProbe],
            environment: [:], currentDirectory: nil)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "pipe\nopen\n")
    }

    func testRunProfileGivesTheGameAnOpenEmptyStdin() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BasaltRunProfileInput-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("data", isDirectory: true)
        let directory = root.appendingPathComponent("Bottles/Test", isDirectory: true)
        let prefix = directory.appendingPathComponent("prefix", isDirectory: true)
        let engineRoot = directory.appendingPathComponent("engine", isDirectory: true)
        let wine = engineRoot.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(
            at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        // A stand-in for hello_xr: it waits for a key press and quits on EOF.
        try Data("#!/bin/sh\n\(Self.stdinProbe)\n".utf8).write(to: wine)
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
            name: "hello-xr", bottleName: "Test", source: .direct,
            executable: #"C:\Games\hello_xr\khr_hello_xr_d3d11.exe"#,
            arguments: ["--graphics", "D3D11"]))
        let control = temporary.appendingPathComponent("control")
        try Data("123 token".utf8).write(to: control)

        let result = try manager.runProfile("hello-xr", controlFile: control)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "open\n")
    }

    /// Prints "open" if stdin is still open with no data after 1 s, "eof" if it ends first.
    private static let stdinProbe =
        #"trap 'echo open; exit 0' ALRM; (sleep 1; kill -ALRM $$) & w=$!; read x; kill $w; echo eof"#

    private static func openDescriptors() -> Set<Int32> {
        Set((0..<Int32(getdtablesize())).filter { fcntl($0, F_GETFD) != -1 })
    }
}
