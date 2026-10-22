import XCTest
@testable import BasaltCore

/// Regression for "network busy, not encoded" drops on an idle link: the
/// pre-encode check counted any write in flight as busy, even one that had
/// started 1 ms earlier and would finish long before the ~11 ms encode of the
/// next frame (0.7-1.7% of frames over USB and Wi-Fi, with writes of at most
/// 1.6 ms).
final class AlvrVideoSendAdmissionTests: XCTestCase {
    private let period: UInt64 = 13_888_889 // 72 Hz

    func testShortInFlightSendCausesNoDrop() {
        var admission = AlvrVideoSendAdmission(busyAfterNanoseconds: period)
        let gate = VideoLossRecoveryGate(now: { 0 })
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
        XCTAssertTrue(gate.admit(isIDR: true))

        // Frame N's write starts; frame N+1 arrives 1 ms later.
        XCTAssertTrue(admission.admit(now: 0))
        XCTAssertFalse(admission.wouldDrop(now: 1_000_000), "a 1 ms old write is not a stall")
        XCTAssertEqual(gate.prepareEncode(transportBusy: admission.wouldDrop(now: 1_000_000)),
                       .encode)

        // Its encoded output may meet the same write still running: it waits
        // behind it (one frame queued) instead of being lost.
        XCTAssertTrue(admission.admit(now: 5_000_000))
        XCTAssertTrue(gate.admit(isIDR: false))
        XCTAssertFalse(gate.isAwaitingIDR, "no loss, so no keyframe")

        // Never more than one frame waits behind the write.
        XCTAssertTrue(admission.wouldDrop(now: 5_000_001))
        XCTAssertFalse(admission.admit(now: 5_000_001))

        // The queued frame becomes the write in flight when the first ends.
        admission.complete(now: 6_000_000)
        XCTAssertEqual(admission.outstanding, 1)
        XCTAssertFalse(admission.wouldDrop(now: 6_000_000 + period))
        XCTAssertTrue(admission.wouldDrop(now: 6_000_001 + period))
        admission.complete(now: 7_000_000)
        XCTAssertEqual(admission.outstanding, 0)
        XCTAssertFalse(admission.wouldDrop(now: 7_000_000 + 10 * period))
    }

    func testLongInFlightSendDropsAndRequestsAKeyframe() {
        var admission = AlvrVideoSendAdmission(busyAfterNanoseconds: period)
        let gate = VideoLossRecoveryGate(now: { 0 })
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
        XCTAssertTrue(gate.admit(isIDR: true))

        // A paused USB link: the write is older than one frame period.
        XCTAssertTrue(admission.admit(now: 0))
        XCTAssertTrue(admission.wouldDrop(now: period + 1))
        XCTAssertEqual(gate.prepareEncode(transportBusy: admission.wouldDrop(now: period + 1)),
                       .skipTransportBusy, "not encoded, as before")

        // A frame already encoding when the stall began is dropped at send,
        // which starts the IDR recovery.
        XCTAssertFalse(admission.admit(now: period + 1))
        XCTAssertTrue(gate.frameLost())
        XCTAssertFalse(gate.admit(isIDR: false), "P-frames are held")

        admission.complete(now: 2 * period)
        XCTAssertFalse(admission.wouldDrop(now: 2 * period))
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
        XCTAssertTrue(gate.admit(isIDR: true))
    }

    func testBusyThresholdIsOneFramePeriodAtTheNegotiatedRate() {
        XCTAssertEqual(AlvrVideoSendAdmission.busyAfterNanoseconds(refreshRate: 72), 13_888_889)
        XCTAssertEqual(AlvrVideoSendAdmission.busyAfterNanoseconds(refreshRate: 120), 8_333_333)
        XCTAssertNil(AlvrVideoSendAdmission.busyAfterNanoseconds(refreshRate: 0))
        XCTAssertNil(AlvrVideoSendAdmission.busyAfterNanoseconds(refreshRate: .nan))
        XCTAssertNil(AlvrVideoSendAdmission.busyAfterNanoseconds(refreshRate: 1_000))
        XCTAssertEqual(AlvrVideoStreamSender.defaultInFlightBusyAfterNanoseconds, 13_888_889)
    }
}
