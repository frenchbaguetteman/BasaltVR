import XCTest
@testable import BasaltManagerKit

final class SessionHistoryTests: XCTestCase {
    func testSummaryAggregatesEverySeriesAndCountsLowFrameRates() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            StreamMetricSample(date: start, fps: 72),
            StreamMetricSample(date: start, megabits: 30),
            StreamMetricSample(date: start, fps: 60, latencyMilliseconds: 50),
            StreamMetricSample(date: start, fps: 66, latencyMilliseconds: 70),
            StreamMetricSample(date: start, fps: .nan),
        ]

        let summary = StreamMetricSummary(samples: samples, targetFPS: 72)

        XCTAssertEqual(summary.fps.count, 3)
        XCTAssertEqual(summary.fps.average, 66)
        XCTAssertEqual(summary.fps.minimum, 60)
        XCTAssertEqual(summary.fps.maximum, 72)
        // 60 is below 0.9 × 72 = 64.8; 66 is not.
        XCTAssertEqual(summary.lowFrameRateSamples, 1)
        XCTAssertEqual(try XCTUnwrap(summary.lowFrameRateShare), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(summary.megabits.average, 30)
        XCTAssertEqual(summary.latencyMilliseconds.average, 60)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(StreamMetricSummary().isEmpty)
        XCTAssertNil(StreamMetricSummary().fps.average)
    }

    func testStreamingDurationExcludesStartup() {
        var record = SessionRecord(
            profileName: "beat-saber", settings: StreamLaunchSettings(),
            startedAt: Date(timeIntervalSince1970: 100))
        XCTAssertNil(record.streamingDuration)
        record.streamingStartedAt = Date(timeIntervalSince1970: 130)
        record.endedAt = Date(timeIntervalSince1970: 730)
        XCTAssertEqual(record.streamingDuration, 600)
    }

    func testStorePrependsCapsAndRoundTrips() throws {
        let store = SessionHistoryStore(
            file: try temporaryDirectory().appendingPathComponent("nested/history.json"),
            limit: 3)
        XCTAssertEqual(store.load(), [])

        var records = [SessionRecord]()
        for index in 0..<5 {
            var record = SessionRecord(
                profileName: "game-\(index)", settings: StreamLaunchSettings(),
                startedAt: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + index)))
            record.outcome = .stopped
            record.metrics.add(StreamMetricSample(fps: 72), targetFPS: 72)
            records.append(record)
            try store.append(record)
        }

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.profileName), ["game-4", "game-3", "game-2"])
        XCTAssertEqual(loaded.first, records[4])

        var updated = records[4]
        updated.outcome = .ended
        XCTAssertEqual(try store.append(updated).map(\.profileName), ["game-4", "game-3", "game-2"])
        XCTAssertEqual(store.load().first?.outcome, .ended)

        try store.clear()
        XCTAssertEqual(store.load(), [])
        try store.clear()
    }

    func testStoreSkipsUnreadableRecordsAndToleratesCorruptFiles() throws {
        let file = try temporaryDirectory().appendingPathComponent("history.json")
        let store = SessionHistoryStore(file: file)
        // History stores whole-second ISO 8601 dates.
        var record = SessionRecord(
            profileName: "kept", settings: StreamLaunchSettings(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        record.outcome = .failed
        record.failureReason = "Steam is open but not signed in."
        try store.append(record)

        // A record from a future format must not discard the readable ones.
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(
            of: #""sessions" : ["#,
            with: #""sessions" : [ { "id" : "not-a-uuid", "outcome" : "teleported" },"#)
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), [record])

        try "not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(try store.append(record), [record])
    }

    func testMetricsCSV() {
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        let csv = StreamMetricCSV.render([
            StreamMetricSample(date: date, fps: 72.5),
            StreamMetricSample(date: date, megabits: 28, latencyMilliseconds: .infinity),
        ])
        XCTAssertEqual(csv, """
            timestamp,quest_fps,wire_mbps,input_to_display_ms
            2027-01-15T08:00:00.250Z,72.5,,
            2027-01-15T08:00:00.250Z,,28.0,

            """)
        XCTAssertEqual(StreamMetricCSV.render([]), StreamMetricCSV.header + "\n")
    }
}
