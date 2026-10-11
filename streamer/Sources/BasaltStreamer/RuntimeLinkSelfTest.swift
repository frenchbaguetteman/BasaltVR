import Foundation
import CoreMedia
import CoreVideo
import BasaltCore

/// Local M3 acceptance for the runtime→streamer boundary: receives
/// fence-confirmed frames from the OpenXR runtime under Wine over the
/// control socket and pushes each one, zero-copy, through the VideoToolbox
/// H.264 encoder. Passing means OpenXR-submitted frames become encodable
/// video on the host — the ALVR transport leg is already validated by M2.
///
/// Usage: basalt-streamer runtime-link-selftest \
///            --control-file <path> [--frames N] [--timeout seconds]
enum RuntimeLinkSelfTest {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var encoder: H264Encoder?
        var framesReceived: UInt64 = 0
        var framesEncoded: UInt64 = 0
        var encodedBytes: UInt64 = 0
        var keyframes: UInt64 = 0
        var expectedTrackingTimestamps = Set<UInt64>()
        var encodedTrackingTimestamps = Set<UInt64>()
        var tornDown = false
        var failure: String?

        func withLock<T>(_ body: (State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }

        /// Lazily creates the encoder from the first frame's dimensions.
        func encoderFor(width: Int, height: Int) -> H264Encoder? {
            lock.lock()
            defer { lock.unlock() }
            if let encoder { return encoder }
            do {
                let created = try H264Encoder(
                    width: width, height: height, fps: 72, bitrate: 10_000_000
                ) { [weak self] annexB, isKeyframe, pts in
                    guard let self else { return }
                    self.lock.lock()
                    self.framesEncoded += 1
                    self.encodedBytes += UInt64(annexB.count)
                    if isKeyframe { self.keyframes += 1 }
                    if let timestamp = H264Encoder.questTrackingTimestampNanoseconds(from: pts) {
                        self.encodedTrackingTimestamps.insert(timestamp)
                    } else {
                        self.failure = "encoder did not preserve the runtime tracking timestamp PTS"
                    }
                    self.lock.unlock()
                }
                created.onError = { [weak self] error in
                    self?.withLock { $0.failure = "encoder: \(error.localizedDescription)" }
                }
                encoder = created
                return created
            } catch {
                failure = "encoder creation failed: \(error.localizedDescription)"
                return nil
            }
        }
    }

    static func run(_ arguments: [String]) async {
        var controlFile: String?
        var expectedFrames: UInt64 = 21
        var timeoutSeconds = 120
        var remaining = arguments
        while !remaining.isEmpty {
            let flag = remaining.removeFirst()
            switch flag {
            case "--control-file" where !remaining.isEmpty:
                controlFile = remaining.removeFirst()
            case "--frames" where !remaining.isEmpty:
                expectedFrames = UInt64(remaining.removeFirst()) ?? expectedFrames
            case "--timeout" where !remaining.isEmpty:
                timeoutSeconds = Int(remaining.removeFirst()) ?? timeoutSeconds
            default:
                fputs("usage: runtime-link-selftest --control-file <path> [--frames N] [--timeout s]\n",
                      stderr)
                exit(2)
            }
        }
        guard let controlFile else {
            fputs("runtime-link-selftest: --control-file is required\n", stderr)
            exit(2)
        }

        let state = State()
        do {
            let link = try RuntimeLink(controlFilePath: controlFile)
            link.onHello = { sessionId, renderer in
                print("runtime-link: hello from session \(sessionId) (\(renderer))")
            }
            link.onSwapchain = { swapchain in
                print("runtime-link: swapchain \(swapchain.id) " +
                      "(\(swapchain.width)x\(swapchain.height), " +
                      "\(swapchain.surfaces.count) IOSurfaces)")
            }
            link.onFrame = { frame, consumption in
                defer { consumption.complete() }
                guard let view = frame.views.first else { return }
                let width = IOSurfaceGetWidth(view.surface)
                let height = IOSurfaceGetHeight(view.surface)
                guard let encoder = state.encoderFor(width: width, height: height) else {
                    return
                }
                var maybeBuffer: Unmanaged<CVPixelBuffer>?
                let status = CVPixelBufferCreateWithIOSurface(
                    kCFAllocatorDefault, view.surface, nil, &maybeBuffer)
                guard status == kCVReturnSuccess,
                      let buffer = maybeBuffer?.takeRetainedValue() else {
                    state.withLock { $0.failure = "CVPixelBufferCreateWithIOSurface: \(status)" }
                    return
                }
                guard let pts = H264Encoder.presentationTime(
                        questTrackingTimestampNanoseconds:
                            frame.questTrackingTimestampNanoseconds) else {
                    state.withLock { $0.failure = "invalid runtime tracking timestamp" }
                    return
                }
                guard encoder.encode(buffer, pts: pts) else {
                    state.withLock { $0.failure = "encoder rejected a self-test frame" }
                    return
                }
                state.withLock {
                    $0.framesReceived += 1
                    $0.expectedTrackingTimestamps.insert(
                        frame.questTrackingTimestampNanoseconds)
                }
                // Deterministic frame-in/frame-out for the acceptance count.
                encoder.flush()
            }
            link.onTeardown = {
                state.withLock { $0.tornDown = true }
            }
            link.onProtocolError = { reason in
                state.withLock { $0.failure = "runtime connection refused: \(reason)" }
            }
            try await link.start()
            print("runtime-link: control file ready at \(controlFile)")

            let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
            while Date() < deadline {
                let (done, failed) = state.withLock { state in
                    (state.tornDown && state.framesEncoded >= min(state.framesReceived, expectedFrames),
                     state.failure != nil)
                }
                if done || failed { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            link.stop()
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        let summary = state.withLock { state in
            (received: state.framesReceived, encoded: state.framesEncoded,
             bytes: state.encodedBytes, keyframes: state.keyframes,
             timestampsMatch: state.expectedTrackingTimestamps == state.encodedTrackingTimestamps,
             tornDown: state.tornDown, failure: state.failure)
        }
        if let failure = summary.failure {
            fputs("FAIL: \(failure)\n", stderr)
            exit(1)
        }
        guard summary.received >= expectedFrames, summary.encoded >= expectedFrames,
              summary.bytes > 0, summary.keyframes > 0, summary.timestampsMatch,
              summary.tornDown else {
            fputs("FAIL: received \(summary.received), encoded \(summary.encoded) " +
                  "(expected \(expectedFrames)), keyframes \(summary.keyframes), " +
                  "tracking timestamps \(summary.timestampsMatch), " +
                  "teardown \(summary.tornDown)\n", stderr)
            exit(1)
        }
        print("PASS: encoded \(summary.encoded) runtime frames to H.264 " +
              "(\(summary.bytes) bytes, \(summary.keyframes) keyframes, clean teardown)")
    }
}
