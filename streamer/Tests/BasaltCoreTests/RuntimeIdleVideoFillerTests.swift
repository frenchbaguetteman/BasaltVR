import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import BasaltCore

private let millisecond: UInt64 = 1_000_000

final class RuntimeIdleVideoFillerTests: XCTestCase {
    private typealias Filler = RuntimeIdleVideoFiller<String>

    private func makeFiller() -> Filler {
        Filler(idleThresholdNanoseconds: 500 * millisecond,
               intervalNanoseconds: 100 * millisecond,
               poseWindowNanoseconds: 2_000 * millisecond)
    }

    func testNoGameFrameYetSendsBlackUntilOneBlackFrameIsDelivered() throws {
        let filler = makeFiller()
        // Nothing to feed: no client, or no fresh Quest tracking.
        XCTAssertNil(filler.nextFrame(now: 0, latestTrackingTimestamp: 50,
                                      hasStream: false, referenceChainBroken: true))
        XCTAssertNil(filler.nextFrame(now: 0, latestTrackingTimestamp: nil,
                                      hasStream: true, referenceChainBroken: true))

        let first = try XCTUnwrap(filler.nextFrame(
            now: 0, latestTrackingTimestamp: 1_000, hasStream: true, referenceChainBroken: true))
        guard case .black(let timestamp) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(timestamp, 1_000)
        XCTAssertEqual(first.presentationNanoseconds, 1_000)
        // Not delivered yet (for example the encoder was busy): retried at
        // the interval, with newer tracking only.
        XCTAssertNil(filler.nextFrame(now: 50 * millisecond, latestTrackingTimestamp: 2_000,
                                      hasStream: true, referenceChainBroken: true))
        let retry = try XCTUnwrap(filler.nextFrame(
            now: 100 * millisecond, latestTrackingTimestamp: 2_000, hasStream: true,
            referenceChainBroken: true))
        XCTAssertEqual(retry.trackingTimestampNanoseconds, 2_000)
        filler.recordDelivered(presentationNanoseconds: retry.presentationNanoseconds)

        // Delivered on an intact chain: ALVR keeps showing it, so no more
        // black frames are needed.
        for tick in 3...40 {
            XCTAssertNil(filler.nextFrame(
                now: UInt64(tick) * 100 * millisecond,
                latestTrackingTimestamp: 2_000 + UInt64(tick), hasStream: true,
                referenceChainBroken: false))
        }
        // The Quest asks for an IDR: one more black frame.
        let repair = try XCTUnwrap(filler.nextFrame(
            now: 5_000 * millisecond, latestTrackingTimestamp: 9_000, hasStream: true,
            referenceChainBroken: true))
        XCTAssertFalse(repair.isRepeat)
    }

    func testAfterAGameFrameTheFillerRepeatsThatImageNeverBlack() throws {
        let filler = makeFiller()
        let frameTimestamp: UInt64 = 10_000 * millisecond
        XCTAssertTrue(filler.admitRuntimeFrame(trackingTimestampNanoseconds: frameTimestamp,
                                               now: 0))
        filler.holdComposedFrame("game frame", trackingTimestampNanoseconds: frameTimestamp)
        // The encoder or transport was busy, so the frame never reached the
        // headset. While the game still renders, nothing is inserted.
        XCTAssertNil(filler.nextFrame(now: 400 * millisecond,
                                      latestTrackingTimestamp: frameTimestamp + 400 * millisecond,
                                      hasStream: true, referenceChainBroken: false))

        let repeated = try XCTUnwrap(filler.nextFrame(
            now: 500 * millisecond, latestTrackingTimestamp: frameTimestamp + 500 * millisecond,
            hasStream: true, referenceChainBroken: false))
        guard case .repeatLast(let image, let timestamp, let presentation) = repeated else {
            return XCTFail("expected a repeat, got \(repeated)")
        }
        XCTAssertEqual(image, "game frame")
        // The client reprojects with the pose this image was rendered for.
        XCTAssertEqual(timestamp, frameTimestamp)
        // VideoToolbox time still moves forward.
        XCTAssertGreaterThan(presentation, frameTimestamp)
        XCTAssertEqual(filler.videoTimestamp(forPresentationNanoseconds: presentation),
                       frameTimestamp)
        XCTAssertEqual(filler.videoTimestamp(forPresentationNanoseconds: frameTimestamp),
                       frameTimestamp, "game frames keep their own timestamp")

        filler.recordDelivered(presentationNanoseconds: presentation)
        XCTAssertNil(filler.nextFrame(now: 600 * millisecond,
                                      latestTrackingTimestamp: frameTimestamp + 600 * millisecond,
                                      hasStream: true, referenceChainBroken: false))

        // A lost access unit or a Quest IDR request: the same image again,
        // at a later presentation time.
        let recovery = try XCTUnwrap(filler.nextFrame(
            now: 700 * millisecond, latestTrackingTimestamp: frameTimestamp + 700 * millisecond,
            hasStream: true, referenceChainBroken: true))
        XCTAssertTrue(recovery.isRepeat)
        XCTAssertEqual(recovery.trackingTimestampNanoseconds, frameTimestamp)
        XCTAssertGreaterThan(recovery.presentationNanoseconds, presentation)

        // A game frame not newer than the repeat would run encoder time
        // backwards; a newer one resumes the game.
        XCTAssertFalse(filler.admitRuntimeFrame(
            trackingTimestampNanoseconds: recovery.presentationNanoseconds, now: 750 * millisecond))
        XCTAssertTrue(filler.admitRuntimeFrame(
            trackingTimestampNanoseconds: frameTimestamp + 740 * millisecond,
            now: 760 * millisecond))
    }

    func testASlowGameIsNeverInterleavedWithBlackFrames() {
        // The Lab's Secret Shop on hardware: about 0.5 game frames/s.
        let filler = makeFiller()
        var sent = [Filler.Frame]()
        var trackingClock: UInt64 = 5_000 * millisecond
        for tick in 0..<400 {   // 20 s at the streamer's 50 ms timer
            let now = UInt64(tick) * 50 * millisecond
            trackingClock += 50 * millisecond
            if tick.isMultiple(of: 40) {   // one game frame every 2 s
                XCTAssertTrue(filler.admitRuntimeFrame(trackingTimestampNanoseconds: trackingClock,
                                                       now: now))
                filler.holdComposedFrame("frame \(tick)",
                                         trackingTimestampNanoseconds: trackingClock)
                filler.recordDelivered(presentationNanoseconds: trackingClock)
            }
            if let frame = filler.nextFrame(now: now, latestTrackingTimestamp: trackingClock,
                                            hasStream: true, referenceChainBroken: false) {
                sent.append(frame)
            }
        }
        XCTAssertTrue(sent.isEmpty, "the headset already shows the last game image: \(sent)")
    }

    func testAGameAt30To60FpsNeverGetsFillerFrames() {
        // Robot Repair renders about 35 fps; 30 fps is the slowest normal game.
        for fps in [30.0, 35.0, 60.0] {
            let filler = makeFiller()
            let frameInterval = UInt64(1_000_000_000 / fps)
            var nextGameFrame: UInt64 = 0
            var trackingClock: UInt64 = 1_000 * millisecond
            for tick in 0..<(10_000 / 5) {   // 10 s in 5 ms steps
                let now = UInt64(tick) * 5 * millisecond
                trackingClock = 1_000 * millisecond + now
                if now >= nextGameFrame {
                    nextGameFrame += frameInterval
                    XCTAssertTrue(filler.admitRuntimeFrame(
                        trackingTimestampNanoseconds: trackingClock, now: now))
                    filler.holdComposedFrame("frame", trackingTimestampNanoseconds: trackingClock)
                    // Worst case: nothing delivered and the chain broken.
                }
                XCTAssertNil(filler.nextFrame(now: now, latestTrackingTimestamp: trackingClock,
                                              hasStream: true, referenceChainBroken: true),
                             "\(fps) fps at \(now / millisecond) ms")
            }
        }
    }

    func testHeadsetDisconnectStopsTheFillerAndTheNextSessionStartsOnBlack() throws {
        let filler = makeFiller()
        let frameTimestamp: UInt64 = 3_000 * millisecond
        _ = filler.admitRuntimeFrame(trackingTimestampNanoseconds: frameTimestamp, now: 0)
        filler.holdComposedFrame("game frame", trackingTimestampNanoseconds: frameTimestamp)

        // No client: nothing is sent.
        XCTAssertNil(filler.nextFrame(now: 1_000 * millisecond,
                                      latestTrackingTimestamp: frameTimestamp + 1,
                                      hasStream: false, referenceChainBroken: true))
        // The session ended; the next client has its own pose history.
        filler.discardHeldFrame()
        XCTAssertFalse(filler.hasHeldFrame)
        let next = try XCTUnwrap(filler.nextFrame(
            now: 1_100 * millisecond, latestTrackingTimestamp: frameTimestamp + 900 * millisecond,
            hasStream: true, referenceChainBroken: true))
        XCTAssertFalse(next.isRepeat)
    }

    func testRuntimeDisconnectFallsBackToBlack() throws {
        let filler = makeFiller()
        let frameTimestamp: UInt64 = 3_000 * millisecond
        _ = filler.admitRuntimeFrame(trackingTimestampNanoseconds: frameTimestamp, now: 0)
        filler.holdComposedFrame("game frame", trackingTimestampNanoseconds: frameTimestamp)
        filler.recordDelivered(presentationNanoseconds: frameTimestamp)
        XCTAssertNil(filler.nextFrame(now: 600 * millisecond,
                                      latestTrackingTimestamp: frameTimestamp + 600 * millisecond,
                                      hasStream: true, referenceChainBroken: false))

        filler.discardHeldFrame()   // "OpenXR runtime disconnected"
        let black = try XCTUnwrap(filler.nextFrame(
            now: 700 * millisecond, latestTrackingTimestamp: frameTimestamp + 700 * millisecond,
            hasStream: true, referenceChainBroken: false))
        guard case .black(let timestamp) = black else { return XCTFail("\(black)") }
        XCTAssertEqual(timestamp, frameTimestamp + 700 * millisecond)
        filler.recordDelivered(presentationNanoseconds: black.presentationNanoseconds)
        XCTAssertNil(filler.nextFrame(now: 800 * millisecond,
                                      latestTrackingTimestamp: frameTimestamp + 800 * millisecond,
                                      hasStream: true, referenceChainBroken: false))

        // The next game's first frame replaces black.
        let resumed = frameTimestamp + 900 * millisecond
        XCTAssertTrue(filler.admitRuntimeFrame(trackingTimestampNanoseconds: resumed,
                                               now: 900 * millisecond))
        filler.holdComposedFrame("next game", trackingTimestampNanoseconds: resumed)
        let repeated = try XCTUnwrap(filler.nextFrame(
            now: 1_400 * millisecond, latestTrackingTimestamp: resumed + 500 * millisecond,
            hasStream: true, referenceChainBroken: false))
        XCTAssertTrue(repeated.isRepeat)
    }

    func testNoRepeatOnceTheClientNoLongerHasThatFramesPose() {
        let filler = makeFiller()
        let frameTimestamp: UInt64 = 3_000 * millisecond
        _ = filler.admitRuntimeFrame(trackingTimestampNanoseconds: frameTimestamp, now: 0)
        filler.holdComposedFrame("game frame", trackingTimestampNanoseconds: frameTimestamp)
        // ALVR keeps 1024 head poses (2.8 s at 120 Hz). A repeat after that
        // would be drawn at a default pose; the client's own copy is better.
        XCTAssertNil(filler.nextFrame(now: 2_500 * millisecond,
                                      latestTrackingTimestamp: frameTimestamp + 2_500 * millisecond,
                                      hasStream: true, referenceChainBroken: true))
        XCTAssertTrue(filler.hasHeldFrame)
    }
}

/// Drives the filler, the loss-recovery gate, and real VideoToolbox output
/// through an idle stretch, then checks the stream the Quest would decode.
final class RuntimeIdleRepeatEncoderTests: XCTestCase {
    private struct Output {
        let annexB: Data
        let isKeyframe: Bool
        let presentation: UInt64
        let alvrTimestamp: UInt64
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

    /// 10 game frames at 30 fps, an idle stretch with a Quest IDR request
    /// (repeat as a forced IDR), one game frame the busy transport skipped
    /// (repeated later as a P-frame), then 5 more game frames.
    private func run(codec: VideoCodec) throws -> (delivered: [Output], repeats: Int) {
        // The test's clock is simulated; the gate's request throttle uses the
        // real one, so it is off here.
        let gate = VideoLossRecoveryGate(clientRequestThrottleNanoseconds: 0)
        let filler = RuntimeIdleVideoFiller<CVPixelBuffer>()
        let lock = NSLock()
        var delivered = [Output]()
        var droppedByEncoder = 0
        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(width: 256, height: 256, fps: 72, bitrate: 4_000_000,
                                       keyframeIntervalSeconds: 60, codec: codec) {
                annexB, isKeyframe, pts in
                guard gate.admit(isIDR: isKeyframe) else { return }
                let presentation = UInt64(CMTimeConvertScale(
                    pts, timescale: 1_000_000_000, method: .default).value)
                lock.lock()
                delivered.append(Output(
                    annexB: annexB, isKeyframe: isKeyframe, presentation: presentation,
                    alvrTimestamp: filler.videoTimestamp(forPresentationNanoseconds: presentation)))
                lock.unlock()
                filler.recordDelivered(presentationNanoseconds: presentation)
                if isKeyframe { gate.idrDelivered() }
            }
        } catch {
            throw XCTSkip("VideoToolbox \(codec.displayName) is unavailable here: \(error)")
        }
        encoder.onFrameEncoded = { _, dropped in
            if dropped {
                lock.lock()
                droppedByEncoder += 1
                lock.unlock()
            }
        }

        func encode(_ buffer: CVPixelBuffer, presentation: UInt64, busy: Bool = false) {
            switch gate.prepareEncode(transportBusy: busy) {
            case .skipTransportBusy, .skipRecoveryBackoff: return
            case .encodeKeyframe: encoder.forceKeyframe()
            case .encode: break
            }
            XCTAssertTrue(encoder.encode(
                buffer, pts: try! XCTUnwrap(H264Encoder.presentationTime(
                    questTrackingTimestampNanoseconds: presentation))))
            encoder.flush()
        }

        let questClockStart: UInt64 = 1_000_000_000_000
        var now: UInt64 = 0
        var repeats = 0
        func gameFrame(_ index: Int, busy: Bool = false) throws {
            let timestamp = questClockStart + now
            XCTAssertTrue(filler.admitRuntimeFrame(trackingTimestampNanoseconds: timestamp,
                                                   now: now))
            let image = try frame(shade: UInt8(truncatingIfNeeded: index * 7))
            filler.holdComposedFrame(image, trackingTimestampNanoseconds: timestamp)
            encode(image, presentation: timestamp, busy: busy)
            now += 33 * millisecond
        }
        func idle(milliseconds: UInt64) {
            let end = now + milliseconds * millisecond
            while now < end {
                now += 50 * millisecond
                guard let fill = filler.nextFrame(
                        now: now, latestTrackingTimestamp: questClockStart + now,
                        hasStream: true, referenceChainBroken: gate.isAwaitingIDR) else { continue }
                guard case .repeatLast(let image, _, let presentation) = fill else {
                    return XCTFail("black after a game frame: \(fill)")
                }
                repeats += 1
                encode(image, presentation: presentation)
            }
        }

        for index in 0..<10 { try gameFrame(index) }
        idle(milliseconds: 1_000)
        XCTAssertEqual(repeats, 0, "frame 9 was delivered; the headset keeps showing it")
        XCTAssertTrue(gate.clientRequestedIDR())
        idle(milliseconds: 1_000)
        XCTAssertEqual(repeats, 1, "one repeat IDR repairs the picture")
        try gameFrame(10, busy: true)
        idle(milliseconds: 1_000)
        XCTAssertEqual(repeats, 2, "the skipped frame 10 is sent once")
        for index in 11..<16 { try gameFrame(index) }
        encoder.flush()

        lock.lock()
        defer { lock.unlock() }
        if droppedByEncoder > 0 {
            throw XCTSkip("VideoToolbox rate control dropped \(droppedByEncoder) frame(s)")
        }
        return (delivered, repeats)
    }

    private func checkTimestamps(_ delivered: [Output]) {
        // 10 game frames, a repeat IDR of frame 9, a repeat of frame 10,
        // and 5 game frames.
        XCTAssertEqual(delivered.count, 17)
        let presentations = delivered.map(\.presentation)
        XCTAssertEqual(presentations, presentations.sorted())
        XCTAssertEqual(Set(presentations).count, presentations.count,
                       "encoder time strictly increases")
        let timestamps = delivered.map(\.alvrTimestamp)
        XCTAssertEqual(timestamps, timestamps.sorted(), "ALVR timestamps never go backwards")
        // Repeats carry the game frame's own tracking timestamp.
        XCTAssertEqual(delivered[10].alvrTimestamp, delivered[9].alvrTimestamp)
        XCTAssertTrue(delivered[10].isKeyframe, "the Quest's IDR request is answered")
        XCTAssertFalse(delivered[11].isKeyframe,
                       "a frame the busy transport skipped follows as a P-frame")
        XCTAssertGreaterThan(delivered[11].alvrTimestamp, delivered[10].alvrTimestamp)
        XCTAssertEqual(delivered.filter(\.isKeyframe).count, 2)
    }

    func testH264RepeatsKeepTheFrameNumChainAndTimestamps() throws {
        let (delivered, _) = try run(codec: .h264)
        checkTimestamps(delivered)
        var parser = H264FrameNumParser()
        let pictures = delivered.compactMap { parser.parse(accessUnit: $0.annexB) }
        XCTAssertEqual(pictures.count, delivered.count)
        XCTAssertFalse(parser.gapsInFrameNumAllowed)
        XCTAssertEqual(H264FrameNumParser.frameNumGaps(
            pictures, log2MaxFrameNum: try XCTUnwrap(parser.log2MaxFrameNum)), [])
    }

    func testHEVCRepeatsKeepEveryReferenceAndTimestamps() throws {
        let (delivered, _) = try run(codec: .hevc)
        checkTimestamps(delivered)
        var parser = HEVCReferenceParser()
        let pictures = delivered.compactMap { parser.parse(accessUnit: $0.annexB) }
        XCTAssertEqual(pictures.count, delivered.count)
        XCTAssertEqual(HEVCReferenceParser.missingReferences(pictures), [])
        XCTAssertTrue(pictures[11].referencePOCs.count > 0,
                      "the repeat P-frame predicts from the repeat IDR")
    }
}
