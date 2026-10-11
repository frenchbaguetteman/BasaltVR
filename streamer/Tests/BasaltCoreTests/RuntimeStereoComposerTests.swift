import CoreVideo
import XCTest
@testable import BasaltCore

final class RuntimeStereoComposerTests: XCTestCase {
    private final class FrameStore: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [RuntimeStereoComposer.ComposedFrame] = []

        func append(_ frame: RuntimeStereoComposer.ComposedFrame?) {
            guard let frame else { return }
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }

        func first() -> RuntimeStereoComposer.ComposedFrame? {
            lock.lock()
            defer { lock.unlock() }
            return frames.first
        }

        func removeAll() {
            lock.lock()
            frames.removeAll()
            lock.unlock()
        }
    }

    private func pixelBuffer(b: UInt8, g: UInt8, r: UInt8, a: UInt8) throws
        -> CVPixelBuffer
    {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var maybeBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil, 1, 1, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &maybeBuffer),
            kCVReturnSuccess)
        let buffer = try XCTUnwrap(maybeBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        bytes[0] = b
        bytes[1] = g
        bytes[2] = r
        bytes[3] = a
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testOpaqueProjectionPreservesRGBWhenSourceAlphaIsZero() throws {
        let composer = try RuntimeStereoComposer(perEyeWidth: 1, height: 1)
        let left = try pixelBuffer(b: 0, g: 0, r: 255, a: 0)
        let right = try pixelBuffer(b: 0, g: 255, r: 0, a: 0)
        let completed = expectation(description: "asynchronous Metal composition")
        let outputs = FrameStore()
        XCTAssertTrue(composer.composeAsync(left: left, right: right) { frame in
            outputs.append(frame)
            completed.fulfill()
        })
        wait(for: [completed], timeout: 2)
        let pixelBuffer = try XCTUnwrap(outputs.first()?.pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!
            .assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(bytes[2], 240)
        XCTAssertLessThan(bytes[1], 15)
        XCTAssertGreaterThan(bytes[3], 240)
        XCTAssertGreaterThan(bytes[5], 240)
        XCTAssertLessThan(bytes[6], 15)
        XCTAssertGreaterThan(bytes[7], 240)
    }

    func testCompositionHasStrictTwoFrameBoundAndReusesReleasedSlot() throws {
        let composer = try RuntimeStereoComposer(perEyeWidth: 1, height: 1)
        let source = try pixelBuffer(b: 0, g: 0, r: 0, a: 255)
        let outputs = FrameStore()
        let firstTwo = expectation(description: "first two frames complete")
        firstTwo.expectedFulfillmentCount = RuntimeStereoComposer.maximumFramesInFlight

        for _ in 0..<RuntimeStereoComposer.maximumFramesInFlight {
            XCTAssertTrue(composer.composeAsync(left: source, right: source) { frame in
                outputs.append(frame)
                firstTwo.fulfill()
            })
        }
        XCTAssertFalse(composer.composeAsync(left: source, right: source) { _ in
            XCTFail("a third in-flight frame must not be admitted")
        })
        wait(for: [firstTwo], timeout: 2)

        outputs.removeAll()
        let reused = expectation(description: "released slot is reusable")
        XCTAssertTrue(composer.composeAsync(left: source, right: source) { frame in
            XCTAssertNotNil(frame)
            reused.fulfill()
        })
        wait(for: [reused], timeout: 2)
    }
}
