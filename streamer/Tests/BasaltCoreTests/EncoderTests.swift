import CoreMedia
import CoreVideo
import XCTest
@testable import BasaltCore

final class EncoderTests: XCTestCase {
    private func makeEncoder(entropy: H264EntropyMode,
                             output: @escaping H264Encoder.Output) throws -> H264Encoder {
        do {
            return try H264Encoder(width: 256, height: 256, fps: 72, bitrate: 4_000_000,
                                   keyframeIntervalSeconds: 10, entropyMode: entropy,
                                   output: output)
        } catch {
            throw XCTSkip("VideoToolbox H.264 is unavailable here: \(error)")
        }
    }

    private func frame(shade: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_32BGRA,
                                           attributes, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(shade),
               CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    func testEveryFrameReportsOneEncodeEventInBothEntropyModes() throws {
        for entropy in H264EntropyMode.allCases {
            let lock = NSLock()
            var events = [(UInt64, Bool)]()
            var keyframes = 0
            var outputs = 0
            let encoder = try makeEncoder(entropy: entropy) { _, isKeyframe, _ in
                lock.lock()
                outputs += 1
                if isKeyframe { keyframes += 1 }
                lock.unlock()
            }
            encoder.onFrameEncoded = { duration, dropped in
                lock.lock()
                events.append((duration, dropped))
                lock.unlock()
            }
            XCTAssertFalse(encoder.rejectedProperties.contains("H264EntropyMode"), "\(entropy)")
            for index in 0..<3 {
                let submitted = encoder.encode(
                    try frame(shade: UInt8(40 * index)),
                    pts: CMTime(value: Int64(index), timescale: 72))
                XCTAssertTrue(submitted)
                encoder.flush()
            }
            lock.lock()
            XCTAssertEqual(events.count, 3, "\(entropy)")
            XCTAssertEqual(outputs + events.filter(\.1).count, 3, "\(entropy)")
            XCTAssertGreaterThanOrEqual(keyframes, 1, "\(entropy)")
            lock.unlock()
        }
    }
}
