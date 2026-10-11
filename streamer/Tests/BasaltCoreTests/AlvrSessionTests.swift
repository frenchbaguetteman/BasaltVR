import XCTest
@testable import BasaltCore

final class AlvrSessionTests: XCTestCase {
    private let quest = AlvrVideoCapabilities(
        width: 1680, height: 1760, refreshRates: [72, 80, 90, 120],
        microphoneSampleRate: 44_100, supportsFoveatedEncoding: true,
        supportsHighProfile: true, supports10Bit: true, supportsAV1: true,
        prefers10Bit: false, prefersFullRange: true,
        preferredEncodingGamma: 1, prefersHDR: false)

    func testBeatSaberDefaultsPrefer90Hz() throws {
        let settings = try AlvrNegotiatedSettings.beatSaberDefaults(for: quest)
        XCTAssertEqual(settings.width, 1680)
        XCTAssertEqual(settings.height, 1760)
        XCTAssertEqual(settings.refreshRate, 90)
        XCTAssertEqual(settings.gameAudioSampleRate, 48_000)
        XCTAssertFalse(settings.enableHDR)
    }

    func testFallsBackToHighestRefreshRate() throws {
        let capabilities = AlvrVideoCapabilities(
            width: 1_280, height: 1_024, refreshRates: [60, 72], microphoneSampleRate: 44_100,
            supportsFoveatedEncoding: false, supportsHighProfile: true,
            supports10Bit: false, supportsAV1: false, prefers10Bit: false,
            prefersFullRange: false, preferredEncodingGamma: 1, prefersHDR: false)
        XCTAssertEqual(try AlvrNegotiatedSettings.beatSaberDefaults(for: capabilities).refreshRate, 72)
    }

    func testRejectsHeadsetAdvertisedResolutionOutsideSupportedRange() throws {
        // A headset controls the advertised capabilities, so an out-of-range
        // resolution must not flow through into the negotiated settings.
        let oversized = AlvrVideoCapabilities(
            width: 65_534, height: 65_534, refreshRates: [72, 90],
            microphoneSampleRate: 44_100, supportsFoveatedEncoding: false,
            supportsHighProfile: true, supports10Bit: false, supportsAV1: false,
            prefers10Bit: false, prefersFullRange: false,
            preferredEncodingGamma: 1, prefersHDR: false)
        XCTAssertThrowsError(try AlvrNegotiatedSettings.beatSaberDefaults(for: oversized))
    }

    func testDesktopPreviewUsesRequestedQuestAspectAndClosestRefreshRate() throws {
        let settings = try AlvrNegotiatedSettings.desktopPreviewDefaults(
            for: quest,
            requestedWidth: 1_152,
            requestedHeight: 1_216,
            preferredRefreshRate: 72)

        XCTAssertEqual(settings.width, 1_152)
        XCTAssertEqual(settings.height, 1_216)
        XCTAssertEqual(settings.refreshRate, 72)
        XCTAssertFalse(settings.useFullRange)
        XCTAssertEqual(settings.maximumBufferingFrames, 1.5)
        XCTAssertEqual(settings.bufferingHistoryWeight, 0.8)
    }

    func testEncodesBincodeStreamConfigPacket() throws {
        let settings = try AlvrNegotiatedSettings.beatSaberDefaults(for: quest)
        let framed = try AlvrStreamConfigEncoder.framedPacket(settings: settings)
        let framedLength = framed.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        XCTAssertEqual(framedLength, framed.count - 4)

        let payload = Data(framed.dropFirst(4))
        let sessionLength = payload.prefix(8).enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
        let sessionEnd = 8 + Int(sessionLength)
        let session = try XCTUnwrap(JSONSerialization.jsonObject(with: payload[8..<sessionEnd])
                                    as? [String: Any])
        let sessionSettings = try XCTUnwrap(session["session_settings"] as? [String: Any])
        let video = try XCTUnwrap(sessionSettings["video"] as? [String: Any])
        XCTAssertEqual((video["max_buffering_frames"] as? NSNumber)?.doubleValue, 1.5)
        XCTAssertEqual((video["buffering_history_weight"] as? NSNumber)?.doubleValue ?? -1,
                       0.8, accuracy: 0.0001)
        let jsonStart = sessionEnd + 8
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.dropFirst(jsonStart))
                                 as? [String: Any])
        XCTAssertEqual((json["refresh_rate_hint"] as? NSNumber)?.floatValue, 90)
        XCTAssertEqual((json["view_resolution"] as? [NSNumber])?.map(\.uint32Value), [1680, 1760])
        XCTAssertEqual(json["wired"] as? Bool, false)
    }

    func testLowLatencyPresetUsesConservativeBufferReduction() throws {
        let settings = try AlvrNegotiatedSettings.desktopPreviewDefaults(
            for: quest, requestedWidth: 1_152, requestedHeight: 1_216,
            preferredRefreshRate: 72, latencyPreset: .low)
        XCTAssertEqual(settings.maximumBufferingFrames, 1.3)
        XCTAssertEqual(settings.bufferingHistoryWeight, 0.8)
    }

    func testUltraLatencyPresetMinimizesBufferAndHistory() throws {
        let settings = try AlvrNegotiatedSettings.desktopPreviewDefaults(
            for: quest, requestedWidth: 1_152, requestedHeight: 1_216,
            preferredRefreshRate: 90, latencyPreset: .ultra)
        XCTAssertEqual(settings.refreshRate, 90)
        XCTAssertEqual(settings.maximumBufferingFrames, 1.0)
        XCTAssertEqual(settings.bufferingHistoryWeight, 0.5)
    }

    func testRejectsResolutionAboveHeadsetCapabilitiesOrOddDimensions() throws {
        XCTAssertNoThrow(try AlvrNegotiatedSettings.desktopPreviewDefaults(
            for: quest, requestedWidth: 1_680, requestedHeight: 1_760,
            preferredRefreshRate: 72))
        XCTAssertThrowsError(try AlvrNegotiatedSettings.desktopPreviewDefaults(
            for: quest, requestedWidth: 1_682, requestedHeight: 1_760,
            preferredRefreshRate: 72))
        XCTAssertThrowsError(try AlvrNegotiatedSettings.desktopPreviewDefaults(
            for: quest, requestedWidth: 1_680, requestedHeight: 1_762,
            preferredRefreshRate: 72))
        XCTAssertThrowsError(try AlvrNegotiatedSettings.desktopPreviewDefaults(
            for: quest, requestedWidth: 1_151, requestedHeight: 1_216,
            preferredRefreshRate: 72))
    }

    func testWiredStreamConfigEnablesClientTCPTransport() throws {
        let framed = try AlvrStreamConfigEncoder.framedPacket(
            settings: AlvrNegotiatedSettings.beatSaberDefaults(for: quest), wired: true)
        let payload = Data(framed.dropFirst(4))
        let sessionLength = payload.prefix(8).enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
        let negotiatedLengthOffset = 8 + Int(sessionLength)
        let negotiatedLength = payload[negotiatedLengthOffset..<negotiatedLengthOffset + 8]
            .enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << UInt64($1.offset * 8))
            }
        let jsonStart = negotiatedLengthOffset + 8
        let jsonEnd = jsonStart + Int(negotiatedLength)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload[jsonStart..<jsonEnd])
                                 as? [String: Any])
        XCTAssertEqual(json["wired"] as? Bool, true)
    }
}
