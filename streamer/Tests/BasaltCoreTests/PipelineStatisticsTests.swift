import XCTest
@testable import BasaltCore

final class PipelineStatisticsTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testTrackingGapsIncludeAnOpenStallAndBackwardTimestamps() {
        let statistics = PipelineStatistics(nowNanoseconds: 0)
        statistics.recordTracking(timestampNanoseconds: 1_000, arrivalNanoseconds: 10 * ms)
        statistics.recordTracking(timestampNanoseconds: 2_000, arrivalNanoseconds: 24 * ms)
        statistics.recordTracking(timestampNanoseconds: 1_500, arrivalNanoseconds: 38 * ms)

        var snapshot = statistics.snapshot(nowNanoseconds: 40 * ms)
        XCTAssertEqual(snapshot.trackingPackets, 3)
        XCTAssertEqual(snapshot.trackingBackwardTimestamps, 1)
        XCTAssertEqual(snapshot.trackingMaximumGapMilliseconds, 14)
        XCTAssertEqual(snapshot.intervalSeconds, 0.04, accuracy: 1e-9)

        // No packet for 1 s: the open gap is reported while it lasts.
        snapshot = statistics.snapshot(nowNanoseconds: 1_038 * ms)
        XCTAssertEqual(snapshot.trackingPackets, 0)
        XCTAssertEqual(snapshot.trackingMaximumGapMilliseconds, 1_000)
        XCTAssertEqual(snapshot.elapsedSeconds, 1.038, accuracy: 1e-9)
    }

    func testRuntimeFramesSeparateUntrackedFromRepeatedPoses() {
        let statistics = PipelineStatistics(nowNanoseconds: 0)
        for timestamp: UInt64 in [5, 5, 0, 0, 6, 7, 7] {
            statistics.recordRuntimeFrame(trackingTimestampNanoseconds: timestamp)
        }
        let snapshot = statistics.snapshot(nowNanoseconds: 2_000 * ms)
        XCTAssertEqual(snapshot.runtimeFrames, 7)
        XCTAssertEqual(snapshot.runtimeUntrackedFrames, 2)
        XCTAssertEqual(snapshot.runtimeRepeatedTimestamps, 2)
    }

    func testEncodeDropsAndPoseAgeAreAveragedPerInterval() {
        let statistics = PipelineStatistics(nowNanoseconds: 0)
        statistics.recordEncode(durationNanoseconds: 8 * ms, droppedByEncoder: false)
        statistics.recordEncode(durationNanoseconds: 12 * ms, droppedByEncoder: false)
        statistics.recordEncode(durationNanoseconds: 30 * ms, droppedByEncoder: true)
        statistics.recordDrop(.encoderBusy)
        statistics.recordDrop(.compositorBusy)
        statistics.recordDrop(.network)
        statistics.recordDrop(.network)
        statistics.recordDrop(.networkBusy)
        statistics.recordDrop(.awaitingIDR)
        statistics.recordDrop(.awaitingIDR)
        statistics.recordDrop(.awaitingIDR)
        statistics.recordPoseAge(nanoseconds: 20 * ms)
        statistics.recordPoseAge(nanoseconds: 30 * ms)

        let snapshot = statistics.snapshot(nowNanoseconds: 2_000 * ms)
        XCTAssertEqual(snapshot.encodedFrames, 2)
        XCTAssertEqual(snapshot.encoderDroppedFrames, 1)
        XCTAssertEqual(snapshot.encodeAverageMilliseconds, 10)
        XCTAssertEqual(snapshot.encodeMaximumMilliseconds, 12)
        XCTAssertEqual(snapshot.encoderBusyDrops, 1)
        XCTAssertEqual(snapshot.compositorBusyDrops, 1)
        XCTAssertEqual(snapshot.networkDrops, 2)
        XCTAssertEqual(snapshot.networkBusyDrops, 1)
        XCTAssertEqual(snapshot.awaitingIDRDrops, 3)
        XCTAssertEqual(snapshot.poseAgeAverageMilliseconds, 25)
        XCTAssertEqual(snapshot.poseAgeMaximumMilliseconds, 30)

        let next = statistics.snapshot(nowNanoseconds: 4_000 * ms)
        XCTAssertEqual(next.encodedFrames, 0)
        XCTAssertNil(next.encodeAverageMilliseconds)
        XCTAssertNil(next.poseAgeMaximumMilliseconds)
        XCTAssertNil(next.trackingMaximumGapMilliseconds)
    }

    func testTrackingArrivalHistoryFindsNewestMatchAndForgetsOldEntries() {
        var history = TrackingArrivalHistory(capacity: 3)
        history.record(timestampNanoseconds: 10, arrivalNanoseconds: 100)
        history.record(timestampNanoseconds: 20, arrivalNanoseconds: 200)
        history.record(timestampNanoseconds: 20, arrivalNanoseconds: 250)
        XCTAssertEqual(history.arrival(ofTimestamp: 20), 250)
        XCTAssertEqual(history.arrival(ofTimestamp: 10), 100)
        XCTAssertNil(history.arrival(ofTimestamp: 0))

        history.record(timestampNanoseconds: 30, arrivalNanoseconds: 300)
        XCTAssertNil(history.arrival(ofTimestamp: 10))
        XCTAssertEqual(history.arrival(ofTimestamp: 30), 300)
    }
}
