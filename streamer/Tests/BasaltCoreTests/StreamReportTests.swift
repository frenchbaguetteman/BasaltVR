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
}
