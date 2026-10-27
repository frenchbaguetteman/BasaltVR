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

    func testKeepsOnePartialLinePerSource() {
        let console = SessionConsole()
        let streamer = NSObject(), game = NSObject()
        XCTAssertEqual(console.append("Quest 7", from: ObjectIdentifier(streamer)), [])
        XCTAssertEqual(console.append("loading\r\nfra", from: ObjectIdentifier(game),
                                      prefix: "game: "), ["game: loading"])
        XCTAssertEqual(console.append("2.0 fps\n", from: ObjectIdentifier(streamer)),
                       ["Quest 72.0 fps"])
        XCTAssertEqual(console.append("me\nnext\n", from: ObjectIdentifier(game),
                                      prefix: "game: "), ["game: frame", "game: next"])
        XCTAssertEqual(console.log, "game: loading\nQuest 72.0 fps\ngame: frame\ngame: next\n")
    }

    func testFlushesAClosedSourceAndCapsAPendingLine() {
        let console = SessionConsole()
        let pipe = ObjectIdentifier(NSObject())
        XCTAssertEqual(console.append("fatal: no headset", from: pipe), [])
        XCTAssertEqual(console.finish(pipe), ["fatal: no headset"])
        XCTAssertEqual(console.finish(pipe), [])
        XCTAssertEqual(console.log, "fatal: no headset\n")

        let flood = String(repeating: "x", count: SessionConsole.maximumPartialLineBytes + 1)
        XCTAssertEqual(console.append(flood, from: pipe), [flood])
        XCTAssertEqual(console.append("tail\n", from: pipe), ["tail"])
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
