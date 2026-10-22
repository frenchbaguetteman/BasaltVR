import XCTest
@testable import BasaltCore

final class OptionsTests: XCTestCase {
    func testDefaultsAreLocalOnly() throws {
        let options = try XCTUnwrap(StreamerOptions.parse([]))
        XCTAssertEqual(options.port, 9999)
        XCTAssertEqual(options.fps, 72)
        XCTAssertEqual(options.megabits, 30)
        XCTAssertEqual(options.perEyeResolution, .quality)
        XCTAssertEqual(options.latencyPreset, .low)
        XCTAssertEqual(options.bindHost, "127.0.0.1")
        XCTAssertTrue(options.bindIsLoopback)
        XCTAssertFalse(options.discover)
        XCTAssertFalse(options.wired)
        XCTAssertNil(options.audioDeviceName)
        XCTAssertFalse(options.routeAudioToCaptureDevice)
        XCTAssertFalse(options.listAudioDevices)
    }

    func testAllFlags() throws {
        let options = try XCTUnwrap(StreamerOptions.parse(
            ["--port", "8000", "--fps", "72", "--mbps", "40",
             "--resolution", "quality", "--latency", "ultra",
             "--bind", "0.0.0.0", "--discover",
             "--audio-device", "BlackHole 2ch", "--route-audio"]))
        XCTAssertEqual(options.port, 8000)
        XCTAssertEqual(options.fps, 72)
        XCTAssertEqual(options.megabits, 40)
        XCTAssertEqual(options.perEyeResolution, .quality)
        XCTAssertEqual(options.latencyPreset, .ultra)
        XCTAssertEqual(options.bindHost, "0.0.0.0")
        XCTAssertFalse(options.bindIsLoopback)
        XCTAssertTrue(options.discover)
        XCTAssertFalse(options.wired)
        XCTAssertEqual(options.audioDeviceName, "BlackHole 2ch")
        XCTAssertTrue(options.routeAudioToCaptureDevice)
    }

    func testHelpReturnsNil() throws {
        XCTAssertNil(try StreamerOptions.parse(["--help"]))
        XCTAssertNil(try StreamerOptions.parse(["-h"]))
    }

    func testUnknownFlagThrows() {
        XCTAssertThrowsError(try StreamerOptions.parse(["--frobnicate"]))
    }

    func testWiredModeIsExclusiveWithDiscovery() throws {
        let wired = try XCTUnwrap(StreamerOptions.parse(["--wired"]))
        XCTAssertTrue(wired.wired)
        XCTAssertFalse(wired.discover)
        XCTAssertThrowsError(try StreamerOptions.parse(["--wired", "--discover"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--wired", "--wireless"]))
    }

    func testWirelessFlagAndLegacyDiscoveryAlias() throws {
        let wireless = try XCTUnwrap(StreamerOptions.parse(["--wireless"]))
        XCTAssertTrue(wireless.discover)
        XCTAssertFalse(wireless.wired)

        let legacy = try XCTUnwrap(StreamerOptions.parse(["--discover"]))
        XCTAssertEqual(legacy, wireless)
    }

    func testAudioRequiresHeadsetModeAndListDoesNot() throws {
        XCTAssertThrowsError(try StreamerOptions.parse(
            ["--audio-device", "BlackHole 2ch"]))
        XCTAssertThrowsError(try StreamerOptions.parse(
            ["--wired", "--audio-device", " "]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--wired", "--route-audio"]))
        let options = try XCTUnwrap(StreamerOptions.parse(["--list-audio-devices"]))
        XCTAssertTrue(options.listAudioDevices)
    }

    func testMissingValueThrows() {
        XCTAssertThrowsError(try StreamerOptions.parse(["--port"]))
    }

    func testNonNumericValueThrows() {
        XCTAssertThrowsError(try StreamerOptions.parse(["--fps", "fast"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--port", "-1"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--mbps", "0"]))
    }

    func testRejectsValuesOutsideOperationalRanges() {
        XCTAssertThrowsError(try StreamerOptions.parse(["--fps", "241"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--mbps", "501"]))
        XCTAssertNoThrow(try StreamerOptions.parse(["--fps", "240", "--mbps", "500"]))
    }

    func testBindRequiresIPAddress() throws {
        XCTAssertThrowsError(try StreamerOptions.parse(["--bind", "example.com"]))
        let v6 = try XCTUnwrap(StreamerOptions.parse(["--bind", "::1"]))
        XCTAssertTrue(v6.bindIsLoopback)
    }

    func testResolutionPresetsAndCustomDimensions() throws {
        XCTAssertEqual(try StreamerOptions.parse(["--resolution", "performance"])?.perEyeResolution,
                       .performance)
        XCTAssertEqual(try StreamerOptions.parse(["--resolution", "BALANCED"])?.perEyeResolution,
                       .balanced)
        XCTAssertEqual(try StreamerOptions.parse(["--resolution", "quality"])?.perEyeResolution,
                       .quality)
        XCTAssertEqual(try StreamerOptions.parse(["--resolution", "1680X1760"])?.perEyeResolution,
                       try PerEyeResolution(width: 1_680, height: 1_760))
    }

    func testRejectsInvalidResolutionsAndLatencyPreset() {
        for value in ["unknown", "1920", "1920x", "0x1080", "511x512", "512x513",
                      "128x128", "8192x8192"] {
            XCTAssertThrowsError(try StreamerOptions.parse(["--resolution", value]), value)
        }
        XCTAssertThrowsError(try StreamerOptions.parse(["--latency", "extreme"]))
    }

    func testM3ProProfileSuppliesDefaultsAndExplicitFlagsWin() throws {
        let profile = try XCTUnwrap(StreamerOptions.parse(["--wired", "--profile", "M3Pro"]))
        XCTAssertEqual(profile.profile, .m3pro)
        XCTAssertEqual(profile.fps, 72)
        XCTAssertEqual(profile.megabits, 30)
        XCTAssertEqual(profile.perEyeResolution, .balanced)
        XCTAssertEqual(profile.latencyPreset, .low)

        // Explicit flags win before and after the profile.
        let before = try XCTUnwrap(StreamerOptions.parse(
            ["--mbps", "45", "--resolution", "quality", "--profile", "m3pro"]))
        let after = try XCTUnwrap(StreamerOptions.parse(
            ["--profile", "m3pro", "--mbps", "45", "--resolution", "quality"]))
        XCTAssertEqual(before, after)
        XCTAssertEqual(after.megabits, 45)
        XCTAssertEqual(after.perEyeResolution, .quality)
        XCTAssertEqual(after.fps, 72)
        XCTAssertEqual(after.latencyPreset, .low)

        XCTAssertThrowsError(try StreamerOptions.parse(["--profile", "m1"]))
        XCTAssertNil(try XCTUnwrap(StreamerOptions.parse([])).profile)
    }

    func testKeyframeIntervalAndEntropy() throws {
        let defaults = try XCTUnwrap(StreamerOptions.parse([]))
        XCTAssertEqual(defaults.keyframeIntervalSeconds, 2)
        XCTAssertEqual(defaults.entropyMode, .cabac)

        let tuned = try XCTUnwrap(StreamerOptions.parse(
            ["--idr-interval", "10", "--entropy", "CAVLC"]))
        XCTAssertEqual(tuned.keyframeIntervalSeconds, 10)
        XCTAssertEqual(tuned.entropyMode, .cavlc)

        XCTAssertThrowsError(try StreamerOptions.parse(["--idr-interval", "0"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--idr-interval", "61"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--entropy", "huffman"]))
    }

    func testControllerPrediction() throws {
        XCTAssertEqual(try StreamerOptions.parse([])?.controllerPrediction, .full)
        XCTAssertEqual(try StreamerOptions.parse(
            ["--controller-prediction", "ALVR"])?.controllerPrediction, .alvr)
        XCTAssertThrowsError(try StreamerOptions.parse(["--controller-prediction", "none"]))
    }

    func testHandTracking() throws {
        XCTAssertEqual(try StreamerOptions.parse([])?.handTracking, true)
        XCTAssertEqual(try StreamerOptions.parse(["--hand-tracking", "OFF"])?.handTracking, false)
        XCTAssertEqual(try StreamerOptions.parse(["--hand-tracking", "on"])?.handTracking, true)
        XCTAssertThrowsError(try StreamerOptions.parse(["--hand-tracking", "maybe"]))
    }

    func testCodec() throws {
        XCTAssertEqual(try StreamerOptions.parse([])?.codec, .h264)
        XCTAssertEqual(try StreamerOptions.parse(["--codec", "HEVC"])?.codec, .hevc)
        XCTAssertEqual(try StreamerOptions.parse(["--codec", "h265"])?.codec, .hevc)
        XCTAssertEqual(try StreamerOptions.parse(["--codec", "h264"])?.codec, .h264)
        XCTAssertThrowsError(try StreamerOptions.parse(["--codec", "av1"]))
        XCTAssertThrowsError(try StreamerOptions.parse(["--codec"]))
        // A profile does not pick the codec until HEVC has a headset A/B.
        XCTAssertEqual(try StreamerOptions.parse(["--profile", "m3pro"])?.codec, .h264)
        XCTAssertEqual(try StreamerOptions.parse(
            ["--codec", "hevc", "--profile", "m3pro"])?.codec, .hevc)
        // Entropy coding is an H.264 choice.
        XCTAssertThrowsError(try StreamerOptions.parse(
            ["--codec", "hevc", "--entropy", "cavlc"]))
        XCTAssertEqual(try StreamerOptions.parse(
            ["--codec", "h264", "--entropy", "cavlc"])?.entropyMode, .cavlc)
    }
}
