import XCTest
@testable import BasaltCore

final class StreamReportTests: XCTestCase {
    func testQuestLineRoundTripsFrameRateAndLatency() {
        let line = StreamReport.questLine(
            framesPerSecond: 71.94, averageLatencyMilliseconds: 49.21,
            maximumLatencyMilliseconds: 63.0, decodeMilliseconds: 4.2,
            decoderQueueMilliseconds: 1.1, vsyncQueueMilliseconds: 8.3)
        XCTAssertEqual(StreamReport.parse(line), StreamReport.Values(
            questFPS: 71.9, videoMegabits: nil, latencyMilliseconds: 49.2))

        // The first report has no measured frame interval yet.
        let firstReport = StreamReport.questLine(
            framesPerSecond: nil, averageLatencyMilliseconds: 52,
            maximumLatencyMilliseconds: 52, decodeMilliseconds: 0,
            decoderQueueMilliseconds: 0, vsyncQueueMilliseconds: 0)
        XCTAssertEqual(StreamReport.parse(firstReport)?.questFPS, nil)
        XCTAssertEqual(StreamReport.parse(firstReport)?.latencyMilliseconds, 52)
    }

    func testOnlyVideoSendLinesCarryTheWireRate() {
        let video = StreamReport.videoSendLine(
            transport: "USB", framesPerSecond: 72, megabitsPerSecond: 12.43,
            maximumWriteMilliseconds: 0.4, largestFrameKibibytes: 96,
            idrCount: 1, repeatedTimestamps: 0)
        // Transport fps is not the headset's frame rate.
        XCTAssertEqual(StreamReport.parse(video), StreamReport.Values(
            questFPS: nil, videoMegabits: 12.4, latencyMilliseconds: nil))

        let audio = StreamReport.audioSendLine(
            transport: "USB", blocksPerSecond: 100, pcmMegabits: 1.536,
            wireMegabits: 1.6, maximumWriteMilliseconds: 0.2, drops: 0)
        XCTAssertNil(StreamReport.parse(audio))
        XCTAssertNil(StreamReport.parse("USB Quest TESTQUEST00001 is authorized; adb forwards are ready."))
        XCTAssertNil(StreamReport.parse("encoder busy (runtime): dropped 1 frame(s) to bound latency"))
    }

    func testPipelineLineIsReadableAndNeverChartedAsQuestOrVideo() {
        let line = StreamReport.pipelineLine(PipelineStatistics.Snapshot(
            elapsedSeconds: 123.45, intervalSeconds: 2,
            trackingPackets: 144, trackingMaximumGapMilliseconds: 31.25,
            trackingBackwardTimestamps: 1, runtimeFrames: 140,
            runtimeUntrackedFrames: 3, runtimeRepeatedTimestamps: 7,
            encoderBusyDrops: 2, compositorBusyDrops: 1, networkDrops: 0,
            networkBusyDrops: 5, awaitingIDRDrops: 6, encodedFrames: 136, encoderDroppedFrames: 4,
            encodeAverageMilliseconds: 8.14, encodeMaximumMilliseconds: 12.5,
            poseAgeAverageMilliseconds: 24.04, poseAgeMaximumMilliseconds: 40))
        XCTAssertEqual(line,
            "  pipeline t=123.5s: tracking 72.0/s (max gap 31.2 ms, 1 backward); "
            + "runtime 70.0/s (3 untracked, 7 repeated pose); "
            + "encoded 68.0/s (8.1 ms avg, 12.5 ms max); "
            + "drops encoder-busy 2, compositor-busy 1, rate-control 4, network-busy 5, "
            + "network 0, awaiting-IDR 6; "
            + "pose age at send 24.0 ms avg, 40.0 ms max")
        XCTAssertNil(StreamReport.parse(line))

        let empty = StreamReport.pipelineLine(PipelineStatistics.Snapshot())
        XCTAssertTrue(empty.contains("max gap - ms"))
        XCTAssertNil(StreamReport.parse(empty))
    }
}
