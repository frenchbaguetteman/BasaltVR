import XCTest
@testable import BasaltManagerKit

@MainActor
final class SessionConsoleTests: XCTestCase {
    func testReturnsLinesCompletedAcrossChunks() {
        let console = SessionConsole()
        XCTAssertEqual(console.append("Quest 72"), [])
        XCTAssertEqual(console.append(".0 fps\nencoder"), ["Quest 72.0 fps"])
        XCTAssertEqual(console.append(" ready\n"), ["encoder ready"])
        XCTAssertEqual(console.log, "Quest 72.0 fps\nencoder ready\n")
        XCTAssertEqual(console.latestLine, "encoder ready")
    }

    func testTrimsWholeLinesFromTheFront() {
        let console = SessionConsole()
        let line = String(repeating: "x", count: 99) + "\n"
        for index in 0..<1_000 {
            _ = console.append(index == 999 ? "last\n" : line)
        }
        let bytes = console.log.utf8.count
        XCTAssertLessThanOrEqual(bytes, SessionConsole.maximumLogBytes)
        XCTAssertGreaterThanOrEqual(bytes, SessionConsole.retainedLogBytes - line.utf8.count)
        XCTAssertTrue(console.log.hasPrefix(line), "the log must start on a line boundary")
        XCTAssertEqual(console.latestLine, "last")
    }

    func testRestartClearsOutputAndOptionallySamples() {
        let console = SessionConsole()
        _ = console.append("partial")
        console.record(StreamMetricSample(fps: 72))
        console.restart(with: "Launching winecfg…\n", clearingSamples: false)
        XCTAssertEqual(console.log, "Launching winecfg…\n")
        XCTAssertEqual(console.samples.count, 1)
        // The partial line from before the restart is gone.
        XCTAssertEqual(console.append("done\n"), ["done"])

        console.restart()
        XCTAssertEqual(console.log, "")
        XCTAssertTrue(console.samples.isEmpty)
        XCTAssertNil(console.latestLine)
    }

    func testChartsShowARecentWindowOfAllSamples() {
        let console = SessionConsole()
        for index in 0..<(SessionConsole.chartWindow + 10) {
            console.record(StreamMetricSample(fps: Double(index)))
        }
        XCTAssertEqual(console.samples.count, SessionConsole.chartWindow + 10)
        XCTAssertEqual(console.recentSamples.count, SessionConsole.chartWindow)
        XCTAssertEqual(console.recentSamples.first?.fps, 10)
    }
}
