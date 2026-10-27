import XCTest
@testable import BasaltCore

final class AdaptiveVideoBitrateTests: XCTestCase {
    func testPersistentClientSlowdownReducesBitrate() {
        let controller = AdaptiveVideoBitrateController(
            configuredBitrate: 35_000_000, targetFramesPerSecond: 72)
        XCTAssertNil(controller.recordClientStatistics(
            statistics(frameInterval: 13_888_889, latency: 100_000_000),
            nowNanoseconds: 0))
        XCTAssertNil(controller.recordClientStatistics(
            statistics(frameInterval: 27_777_778, latency: 150_000_000),
            nowNanoseconds: 1_000_000_000))

        XCTAssertEqual(controller.recordClientStatistics(
            statistics(frameInterval: 27_777_778, latency: 155_000_000),
            nowNanoseconds: 2_100_000_000), 28_000_000)
        XCTAssertEqual(controller.currentBitrate, 28_000_000)
    }

    func testOneCongestionEventDoesNotPenalizeAnIDR() {
        let controller = AdaptiveVideoBitrateController(
            configuredBitrate: 35_000_000, targetFramesPerSecond: 72)

        XCTAssertNil(controller.recordTransportCongestion(
            nowNanoseconds: 100_000_000))
        XCTAssertEqual(controller.currentBitrate, 35_000_000)
    }

    func testRepeatedTransportCongestionReducesBitrate() {
        let controller = AdaptiveVideoBitrateController(
            configuredBitrate: 35_000_000, targetFramesPerSecond: 72)

        XCTAssertNil(controller.recordTransportCongestion(
            nowNanoseconds: 100_000_000))
        XCTAssertEqual(controller.recordTransportCongestion(
            nowNanoseconds: 600_000_000), 28_000_000)
    }

    func testHealthyIntervalCautiouslyRestoresQuality() {
        let controller = AdaptiveVideoBitrateController(
            configuredBitrate: 35_000_000, targetFramesPerSecond: 72)
        _ = controller.recordTransportCongestion(nowNanoseconds: 100_000_000)
        _ = controller.recordTransportCongestion(nowNanoseconds: 600_000_000)
        let healthy = statistics(
            frameInterval: 13_888_889, latency: 100_000_000,
            decoderQueue: 5_000_000)

        XCTAssertNil(controller.recordClientStatistics(
            healthy, nowNanoseconds: 1_000_000_000))
        let recovered = controller.recordClientStatistics(
            healthy, nowNanoseconds: 13_100_000_000)

        XCTAssertNotNil(recovered)
        XCTAssertGreaterThan(recovered!, 28_000_000)
        XCTAssertLessThanOrEqual(recovered!, 35_000_000)
    }

    func testImplausibleHeadsetLatencyIsIgnoredWithoutOverflow() {
        let controller = AdaptiveVideoBitrateController(
            configuredBitrate: 35_000_000, targetFramesPerSecond: 72)
        // UInt64.max previously trapped on `baseline + 25_000_000`.
        XCTAssertNil(controller.recordClientStatistics(
            statistics(frameInterval: 27_777_778, latency: .max),
            nowNanoseconds: 0))
        XCTAssertNil(controller.recordClientStatistics(
            statistics(frameInterval: 27_777_778,
                       latency: AdaptiveVideoBitrateController
                           .maximumPlausibleLatencyNanoseconds + 1),
            nowNanoseconds: 1_000_000_000))

        // The rejected samples did not poison the latency baseline.
        XCTAssertNil(controller.recordClientStatistics(
            statistics(frameInterval: 13_888_889, latency: 100_000_000),
            nowNanoseconds: 2_000_000_000))
        XCTAssertNil(controller.recordClientStatistics(
            statistics(frameInterval: 27_777_778, latency: 150_000_000),
            nowNanoseconds: 3_000_000_000))
        XCTAssertEqual(controller.recordClientStatistics(
            statistics(frameInterval: 27_777_778, latency: 155_000_000),
            nowNanoseconds: 4_100_000_000), 28_000_000)
    }

    private func statistics(
        frameInterval: UInt64, latency: UInt64,
        decoderQueue: UInt64 = 5_000_000
    ) -> AlvrClientStatistics {
        AlvrClientStatistics(
            targetTimestampNanoseconds: 1,
            frameIntervalNanoseconds: frameInterval,
            videoDecodeNanoseconds: 4_000_000,
            videoDecoderQueueNanoseconds: decoderQueue,
            renderingNanoseconds: 3_000_000,
            vsyncQueueNanoseconds: 5_000_000,
            totalPipelineLatencyNanoseconds: latency)
    }
}
