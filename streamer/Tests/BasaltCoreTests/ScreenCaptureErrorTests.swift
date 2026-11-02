import XCTest
import ScreenCaptureKit
@testable import BasaltCore

/// The streamer prints the Screen Recording hint only after a desktop-capture failure,
/// not after every fatal error (an adb error got it too).
final class ScreenCaptureErrorTests: XCTestCase {
    func testNonCaptureErrorsGetNoScreenRecordingHint() {
        let adb = BasaltError(
            "No authorized USB Quest found by adb; connect a data-capable cable and enable Developer Mode")
        XCTAssertNil(ScreenCaptureError.permissionHint(for: adb))
        XCTAssertNil(ScreenCaptureError.permissionHint(
            for: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))))
    }

    func testCaptureErrorsGetTheScreenRecordingHint() throws {
        let declined = NSError(domain: SCStreamErrorDomain,
                               code: SCStreamError.userDeclined.rawValue)
        let wrapped = ScreenCaptureError(declined)
        let hint = try XCTUnwrap(ScreenCaptureError.permissionHint(for: wrapped))
        XCTAssertTrue(hint.contains("Screen Recording"))
        XCTAssertEqual(wrapped.localizedDescription, declined.localizedDescription)
        XCTAssertNotNil(ScreenCaptureError.permissionHint(for: declined))
        XCTAssertNotNil(ScreenCaptureError.permissionHint(
            for: ScreenCaptureError(BasaltError("No displays found"))))
    }
}
