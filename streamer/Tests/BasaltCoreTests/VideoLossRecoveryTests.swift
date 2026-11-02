import CoreMedia
import CoreVideo
import XCTest
@testable import BasaltCore

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000_000

    var now: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(milliseconds: UInt64) {
        lock.lock()
        value += milliseconds * 1_000_000
        lock.unlock()
    }
}

final class VideoLossRecoveryGateTests: XCTestCase {
    private func makeGate(_ clock: FakeClock, recoveryGapMilliseconds: UInt64 = 0)
        -> VideoLossRecoveryGate {
        VideoLossRecoveryGate(
            clientRequestThrottleNanoseconds: 100_000_000,
            recoveryKeyframeMinimumGapNanoseconds: recoveryGapMilliseconds * 1_000_000,
            now: { clock.now })
    }

    /// Brings a fresh gate to the synced state: first encode is an IDR.
    private func sync(_ gate: VideoLossRecoveryGate) {
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
        XCTAssertTrue(gate.admit(isIDR: true))
        gate.idrDelivered()
    }

    func testStartsAwaitingAnIDR() {
        let gate = makeGate(FakeClock())
        XCTAssertTrue(gate.isAwaitingIDR)
        XCTAssertFalse(gate.admit(isIDR: false))
        sync(gate)
        XCTAssertFalse(gate.isAwaitingIDR)
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encode)
        XCTAssertTrue(gate.admit(isIDR: false))
    }

    func testDropHoldsEveryPFrameUntilAnIDRIsSent() {
        let gate = makeGate(FakeClock())
        sync(gate)
        XCTAssertTrue(gate.admit(isIDR: false))
        XCTAssertTrue(gate.frameLost())
        // P-frames already in the encoder pipeline reference the lost frame.
        XCTAssertFalse(gate.admit(isIDR: false))
        XCTAssertFalse(gate.admit(isIDR: false))
        // The next encode is forced to be an IDR; frames after it follow it.
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encode)
        XCTAssertFalse(gate.admit(isIDR: false))
        XCTAssertTrue(gate.admit(isIDR: true))
        gate.idrDelivered()
        XCTAssertTrue(gate.admit(isIDR: false))
        XCTAssertFalse(gate.isAwaitingIDR)
    }

    func testRepeatedLossesForceIDRsWithoutTheOldOneSecondThrottle() {
        let clock = FakeClock()
        let gate = makeGate(clock)
        sync(gate)
        for _ in 0..<5 {
            clock.advance(milliseconds: 14)
            gate.frameLost()
            XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
            XCTAssertTrue(gate.admit(isIDR: true))
            gate.idrDelivered()
        }
    }

    func testLostIDRIsRequestedAgainAndPFramesStayHeld() {
        let gate = makeGate(FakeClock())
        sync(gate)
        gate.frameLost()
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
        XCTAssertTrue(gate.admit(isIDR: true))
        // The IDR itself did not reach the headset (USB stall, shard loss).
        XCTAssertTrue(gate.frameLost())
        XCTAssertTrue(gate.isAwaitingIDR)
        XCTAssertFalse(gate.admit(isIDR: false))
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
    }

    func testTheSameLossReportedTwiceRequestsOneIDR() {
        let gate = makeGate(FakeClock())
        sync(gate)
        XCTAssertTrue(gate.frameLost())
        XCTAssertFalse(gate.frameLost())
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encode)
    }

    func testBusyTransportSkipsEncodingAndKeepsTheChain() {
        let gate = makeGate(FakeClock())
        sync(gate)
        for _ in 0..<10 {
            XCTAssertEqual(gate.prepareEncode(transportBusy: true), .skipTransportBusy)
        }
        XCTAssertFalse(gate.isAwaitingIDR)
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encode)
        XCTAssertTrue(gate.admit(isIDR: false))
    }

    func testRecoveryIDRWaitsForABusyTransport() {
        let gate = makeGate(FakeClock())
        sync(gate)
        gate.frameLost()
        // Encoding the IDR into a stalled link would only lose it again.
        XCTAssertEqual(gate.prepareEncode(transportBusy: true), .skipTransportBusy)
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
    }

    func testPeriodicIDRAlsoEndsRecovery() {
        let gate = makeGate(FakeClock())
        sync(gate)
        gate.frameLost()
        XCTAssertTrue(gate.admit(isIDR: true))
        XCTAssertTrue(gate.admit(isIDR: false))
    }

    func testWiFiRecoveryGapBacksOffOnlyBetweenRecoveryIDRs() {
        let clock = FakeClock()
        let gate = makeGate(clock, recoveryGapMilliseconds: 250)
        sync(gate)
        // The first loss after a quiet period recovers at once.
        clock.advance(milliseconds: 1_000)
        gate.frameLost()
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
        XCTAssertTrue(gate.admit(isIDR: true))
        gate.frameLost()
        clock.advance(milliseconds: 100)
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .skipRecoveryBackoff)
        clock.advance(milliseconds: 150)
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
        // A new session is never delayed.
        gate.restart()
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
    }

    func testClientRequestsAreThrottledOnlyWhileAnIDRIsInFlight() {
        let clock = FakeClock()
        let gate = makeGate(clock)
        sync(gate)
        clock.advance(milliseconds: 500)
        XCTAssertTrue(gate.clientRequestedIDR())
        XCTAssertFalse(gate.admit(isIDR: false))
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
        // The Quest repeats its request while the IDR is in flight.
        clock.advance(milliseconds: 20)
        XCTAssertFalse(gate.clientRequestedIDR())
        clock.advance(milliseconds: 20)
        XCTAssertTrue(gate.admit(isIDR: true))
        gate.idrDelivered()
        // A request sent before the Quest saw that IDR.
        clock.advance(milliseconds: 50)
        XCTAssertFalse(gate.clientRequestedIDR())
        XCTAssertTrue(gate.admit(isIDR: false))
        // A later request is a new decoder error.
        clock.advance(milliseconds: 100)
        XCTAssertTrue(gate.clientRequestedIDR())
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
    }

    func testAnIDRStuckInFlightDoesNotSilenceTheClientForever() {
        let clock = FakeClock()
        let gate = makeGate(clock)
        sync(gate)
        gate.frameLost()
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
        XCTAssertFalse(gate.clientRequestedIDR())
        clock.advance(milliseconds: 150)
        XCTAssertTrue(gate.clientRequestedIDR())
        XCTAssertEqual(gate.prepareEncode(transportBusy: false), .encodeKeyframe)
    }
}

/// Runs real VideoToolbox output through the gate and a simulated transport,
/// then reads `frame_num` from what the "headset" received.
final class VideoLossRecoveryEncoderTests: XCTestCase {
    private struct Run {
        var allOutputs = [Data]()
        var delivered = [Data]()
        var discarded = 0
    }

    private func frame(shade: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_32BGRA,
                                           attributes, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
            .assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // A moving gradient, so P-frames carry real residuals.
        for row in 0..<256 {
            for column in 0..<256 {
                let offset = row * bytesPerRow + column * 4
                let value = UInt8(truncatingIfNeeded: row &+ column &+ Int(shade))
                base[offset] = value
                base[offset + 1] = value &+ 40
                base[offset + 2] = value &+ 80
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    /// Encodes `frameCount` frames. `transportBusy(i)` says whether the link
    /// is busy when frame `i` would be encoded; `dropsOutput(n)` loses the
    /// n-th encoded access unit after the gate admitted it. Frames listed in
    /// `pipelined` are submitted together with the next frame, so their
    /// output exists before the loss of the earlier one is known.
    private func run(frameCount: Int,
                     transportBusy: (Int) -> Bool = { _ in false },
                     dropsOutput: @escaping @Sendable (Int) -> Bool = { _ in false },
                     pipelined: Set<Int> = [],
                     codec: VideoCodec = .h264) throws -> Run {
        let gate = VideoLossRecoveryGate()
        let lock = NSLock()
        var result = Run()
        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(width: 256, height: 256, fps: 72, bitrate: 4_000_000,
                                       keyframeIntervalSeconds: 60,
                                       codec: codec) { annexB, isKeyframe, _ in
                lock.lock()
                let index = result.allOutputs.count
                result.allOutputs.append(annexB)
                lock.unlock()
                guard gate.admit(isIDR: isKeyframe) else {
                    lock.lock()
                    result.discarded += 1
                    lock.unlock()
                    return
                }
                if dropsOutput(index) {
                    gate.frameLost()
                    return
                }
                lock.lock()
                result.delivered.append(annexB)
                lock.unlock()
                if isKeyframe { gate.idrDelivered() }
            }
        } catch {
            throw XCTSkip("VideoToolbox \(codec.displayName) is unavailable here: \(error)")
        }
        var dropsByEncoder = 0
        encoder.onFrameEncoded = { _, dropped in
            if dropped {
                lock.lock()
                dropsByEncoder += 1
                lock.unlock()
            }
        }
        for index in 0..<frameCount {
            switch gate.prepareEncode(transportBusy: transportBusy(index)) {
            case .skipTransportBusy, .skipRecoveryBackoff:
                continue
            case .encodeKeyframe:
                encoder.forceKeyframe()
            case .encode:
                break
            }
            XCTAssertTrue(encoder.encode(try frame(shade: UInt8(truncatingIfNeeded: index * 3)),
                                         pts: CMTime(value: Int64(index), timescale: 72)))
            if !pipelined.contains(index) { encoder.flush() }
        }
        encoder.flush()
        lock.lock()
        defer { lock.unlock() }
        if dropsByEncoder > 0 {
            throw XCTSkip("VideoToolbox rate control dropped \(dropsByEncoder) frame(s); "
                + "output indices are not deterministic")
        }
        return result
    }

    private func pictures(_ units: [Data]) throws -> (pictures: [H264FrameNumParser.Picture],
                                                      log2MaxFrameNum: Int) {
        var parser = H264FrameNumParser()
        let pictures = units.compactMap { parser.parse(accessUnit: $0) }
        XCTAssertEqual(pictures.count, units.count)
        XCTAssertFalse(parser.gapsInFrameNumAllowed,
                       "the Quest rejects frame_num gaps only when the SPS forbids them")
        return (pictures, try XCTUnwrap(parser.log2MaxFrameNum))
    }

    func testDroppingBeforeEncodeKeepsTheReferenceChainWithoutAnIDR() throws {
        let result = try run(frameCount: 30, transportBusy: { (10..<16).contains($0) })
        let (pictures, log2) = try pictures(result.delivered)
        XCTAssertEqual(pictures.count, 24)
        XCTAssertEqual(pictures.filter(\.isIDR).count, 1, "only the stream's first IDR")
        XCTAssertEqual(H264FrameNumParser.frameNumGaps(pictures, log2MaxFrameNum: log2), [])
        XCTAssertEqual(result.discarded, 0)
    }

    func testAnEncodedFrameLostAfterEncodingWouldLeaveAFrameNumGap() throws {
        // What the Quest received before this change: the stream minus the
        // lost access unit, P-frames continuing against it.
        let result = try run(frameCount: 20)
        var naive = result.allOutputs
        naive.remove(at: 10)
        let (pictures, log2) = try pictures(naive)
        XCTAssertEqual(H264FrameNumParser.frameNumGaps(pictures, log2MaxFrameNum: log2), [10])
    }

    func testALostEncodedFrameHoldsPFramesUntilAForcedIDRIsSent() throws {
        // Frames 10 and 11 are in the encoder together; output 10 is lost,
        // so output 11 (a P-frame that references it) must be discarded.
        let result = try run(frameCount: 24, dropsOutput: { $0 == 10 }, pipelined: [10])
        XCTAssertEqual(result.discarded, 1)
        let (pictures, log2) = try pictures(result.delivered)
        XCTAssertEqual(H264FrameNumParser.frameNumGaps(pictures, log2MaxFrameNum: log2), [])
        XCTAssertEqual(pictures.filter(\.isIDR).count, 2)
        // Delivered: outputs 0–9, then the forced IDR right after the loss.
        XCTAssertTrue(pictures[10].isIDR)
        XCTAssertEqual(pictures.count, result.allOutputs.count - 2)
    }

    func testALostRecoveryIDRIsForcedAgain() throws {
        let result = try run(frameCount: 24, dropsOutput: { $0 == 10 || $0 == 11 })
        let (pictures, log2) = try pictures(result.delivered)
        XCTAssertEqual(H264FrameNumParser.frameNumGaps(pictures, log2MaxFrameNum: log2), [])
        XCTAssertTrue(pictures[10].isIDR)
        XCTAssertEqual(pictures.filter(\.isIDR).count, 2)
        // Output 11 was the first recovery IDR, and it was lost too.
        let (allPictures, _) = try self.pictures(result.allOutputs)
        XCTAssertTrue(allPictures[11].isIDR)
        XCTAssertTrue(allPictures[12].isIDR)
    }

    // MARK: HEVC: the same gate, checked against each P-frame's reference
    // picture set instead of frame_num.

    private func hevcPictures(_ units: [Data]) throws -> [HEVCReferenceParser.Picture] {
        var parser = HEVCReferenceParser()
        let pictures = units.compactMap { parser.parse(accessUnit: $0) }
        XCTAssertEqual(pictures.count, units.count)
        XCTAssertFalse(parser.longTermReferencesPresent,
                       "the parser follows short-term references only")
        return pictures
    }

    func testHEVCDroppingBeforeEncodeKeepsEveryReferenceWithoutAnIDR() throws {
        let result = try run(frameCount: 30, transportBusy: { (10..<16).contains($0) },
                             codec: .hevc)
        let pictures = try hevcPictures(result.delivered)
        XCTAssertEqual(pictures.count, 24)
        XCTAssertEqual(pictures.filter(\.isIDR).count, 1, "only the stream's first IDR")
        XCTAssertTrue(pictures.dropFirst().allSatisfy { !$0.referencePOCs.isEmpty },
                      "VideoToolbox HEVC P-frames predict from earlier pictures")
        XCTAssertEqual(HEVCReferenceParser.missingReferences(pictures), [])
        XCTAssertEqual(result.discarded, 0)
    }

    func testHEVCEncodedFrameLostAfterEncodingWouldLeaveAMissingReference() throws {
        let result = try run(frameCount: 20, codec: .hevc)
        var naive = result.allOutputs
        naive.remove(at: 10)
        let pictures = try hevcPictures(naive)
        XCTAssertEqual(HEVCReferenceParser.missingReferences(pictures).first, 10)
    }

    func testHEVCLostEncodedFrameHoldsPFramesUntilAForcedIDRIsSent() throws {
        let result = try run(frameCount: 24, dropsOutput: { $0 == 10 }, pipelined: [10],
                             codec: .hevc)
        XCTAssertEqual(result.discarded, 1)
        let pictures = try hevcPictures(result.delivered)
        XCTAssertEqual(HEVCReferenceParser.missingReferences(pictures), [])
        XCTAssertEqual(pictures.filter(\.isIDR).count, 2)
        XCTAssertTrue(pictures[10].isIDR)
        XCTAssertEqual(pictures.count, result.allOutputs.count - 2)
    }

    func testHEVCLostRecoveryIDRIsForcedAgain() throws {
        let result = try run(frameCount: 24, dropsOutput: { $0 == 10 || $0 == 11 },
                             codec: .hevc)
        let pictures = try hevcPictures(result.delivered)
        XCTAssertEqual(HEVCReferenceParser.missingReferences(pictures), [])
        XCTAssertTrue(pictures[10].isIDR)
        XCTAssertEqual(pictures.filter(\.isIDR).count, 2)
        let allPictures = try hevcPictures(result.allOutputs)
        XCTAssertTrue(allPictures[11].isIDR)
        XCTAssertTrue(allPictures[12].isIDR)
    }
}
