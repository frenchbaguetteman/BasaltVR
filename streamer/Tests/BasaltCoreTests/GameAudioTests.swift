import XCTest
@testable import BasaltCore

final class GameAudioTests: XCTestCase {
    func testFloatStereoConvertsToLittleEndianPCM16WithClipping() throws {
        let pcm = try StereoPCM16Encoder.encode(
            left: [-2, -1, -0.5, 0, 0.5, 1, 2, .nan],
            right: [1, 0.25, 0, -0.25, -1, 0, 0.75, .infinity])
        XCTAssertEqual(pcm, Data([
            0x00, 0x80, 0xff, 0x7f,
            0x00, 0x80, 0x00, 0x20,
            0x00, 0xc0, 0x00, 0x00,
            0x00, 0x00, 0x00, 0xe0,
            0x00, 0x40, 0x00, 0x80,
            0xff, 0x7f, 0x00, 0x00,
            0xff, 0x7f, 0x00, 0x60,
            0x00, 0x00, 0x00, 0x00,
        ]))
    }

    func testStereoConversionRejectsMismatchedChannels() {
        XCTAssertThrowsError(try StereoPCM16Encoder.encode(
            left: [0, 1], right: [0]))
    }
}

final class MicrophoneAccessTests: XCTestCase {
    func testHostAppIsOutermostAppBundleInAncestorChain() {
        XCTAssertEqual(MicrophoneAccess.hostAppName(fromAncestorPaths: [
            "/Users/me/BasaltVR/streamer/.build/release/basalt-streamer",
            "/bin/zsh",
            "/usr/bin/login",
            "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        ]), "Terminal")
        XCTAssertEqual(MicrophoneAccess.hostAppName(fromAncestorPaths: [
            "/tmp/basalt-streamer",
            "/Applications/Example Editor.app/Contents/Frameworks/"
                + "Example Editor Helper.app/Contents/MacOS/Example Editor Helper",
            "/Applications/Example Editor.app/Contents/MacOS/Example Editor",
        ]), "Example Editor")
        XCTAssertNil(MicrophoneAccess.hostAppName(fromAncestorPaths: [
            "/tmp/basalt-streamer", "/usr/sbin/sshd",
        ]))
    }

    func testDeniedHintNamesTheSettingAndTheApp() {
        let hint = MicrophoneAccess.denialHint(state: .denied, hostApp: "Terminal")
        XCTAssertTrue(hint.contains("Privacy & Security > Microphone"))
        XCTAssertTrue(hint.contains("turn on Terminal"))
    }

    func testUnpromptableHintSendsUserToTerminal() {
        let hint = MicrophoneAccess.denialHint(
            state: .notDetermined, hostApp: "Example Editor")
        XCTAssertTrue(hint.contains("Example Editor"))
        XCTAssertTrue(hint.contains("Run the command in Terminal.app and click Allow"))
        XCTAssertTrue(MicrophoneAccess.denialHint(state: .denied, hostApp: nil)
            .contains("your terminal app"))
    }
}
