import Foundation

/// Settings negotiated from the connected headset before the stream socket
/// is opened. This is also the core model the management UI will edit.
public struct AlvrNegotiatedSettings: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let refreshRate: Float
    public let gameAudioSampleRate: UInt32
    public let enableFoveatedEncoding: Bool
    public let useFullRange: Bool
    public let encodingGamma: Float
    public let maximumBufferingFrames: Float
    public let bufferingHistoryWeight: Float

    /// Produces conservative settings for the first Beat Saber path. Prefer
    /// 90 Hz when available, otherwise the highest advertised refresh rate.
    public static func beatSaberDefaults(for capabilities: AlvrVideoCapabilities) throws -> Self {
        try defaults(for: capabilities, requestedWidth: capabilities.width,
                     requestedHeight: capabilities.height, preferredRefreshRate: 90,
                     latencyPreset: .balanced)
    }

    /// Preview configuration for the current desktop capture. Resolution is
    /// per eye; the encoded frame itself is twice this width (side by side).
    public static func desktopPreviewDefaults(
        for capabilities: AlvrVideoCapabilities,
        requestedWidth: UInt32,
        requestedHeight: UInt32,
        preferredRefreshRate: Float,
        latencyPreset: StreamLatencyPreset = .balanced
    ) throws -> Self {
        try defaults(for: capabilities, requestedWidth: requestedWidth,
                     requestedHeight: requestedHeight,
                     preferredRefreshRate: preferredRefreshRate,
                     latencyPreset: latencyPreset)
    }

    private static func defaults(for capabilities: AlvrVideoCapabilities,
                                 requestedWidth: UInt32, requestedHeight: UInt32,
                                 preferredRefreshRate: Float,
                                 latencyPreset: StreamLatencyPreset) throws -> Self {
        guard capabilities.width > 0, capabilities.height > 0,
              !capabilities.refreshRates.isEmpty else {
            throw BasaltError("Headset did not advertise a usable resolution and refresh rate")
        }
        guard requestedWidth > 0, requestedHeight > 0,
              requestedWidth.isMultiple(of: 2), requestedHeight.isMultiple(of: 2) else {
            throw BasaltError("Requested per-eye resolution must use positive even dimensions")
        }
        // A headset advertises its own capabilities, so the values driving the
        // negotiated resolution are untrusted. Reject anything outside the
        // supported range instead of forwarding, e.g., a multi-billion-pixel
        // dimension into the stream configuration.
        let dimensionRange = PerEyeResolution.dimensionRange
        guard dimensionRange.contains(Int(requestedWidth)),
              dimensionRange.contains(Int(requestedHeight)) else {
            throw BasaltError("Per-eye resolution \(requestedWidth)x\(requestedHeight) is outside "
                              + "the supported \(dimensionRange.lowerBound)-\(dimensionRange.upperBound) range")
        }
        guard requestedWidth <= capabilities.width, requestedHeight <= capabilities.height else {
            throw BasaltError("Requested per-eye resolution \(requestedWidth)x\(requestedHeight) exceeds "
                              + "the headset maximum \(capabilities.width)x\(capabilities.height)")
        }
        let validRates = capabilities.refreshRates.filter { $0.isFinite && $0 > 0 && $0 <= 240 }
        guard !validRates.isEmpty else { throw BasaltError("Headset refresh rates are invalid") }
        let refreshRate = validRates.min {
            abs($0 - preferredRefreshRate) < abs($1 - preferredRefreshRate)
        }!
        return Self(
            width: requestedWidth,
            height: requestedHeight,
            refreshRate: refreshRate,
            gameAudioSampleRate: 48_000,
            enableFoveatedEncoding: false,
            // ScreenCaptureKit currently supplies video-range NV12. This can
            // become a user setting once full-range capture/encoding exists.
            useFullRange: false,
            encodingGamma: capabilities.preferredEncodingGamma,
            maximumBufferingFrames: latencyPreset.maximumBufferingFrames,
            bufferingHistoryWeight: latencyPreset.bufferingHistoryWeight,
            enableHDR: false)
    }

    private init(width: UInt32, height: UInt32, refreshRate: Float,
                 gameAudioSampleRate: UInt32, enableFoveatedEncoding: Bool,
                 useFullRange: Bool, encodingGamma: Float,
                 maximumBufferingFrames: Float, bufferingHistoryWeight: Float,
                 enableHDR: Bool) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.gameAudioSampleRate = gameAudioSampleRate
        self.enableFoveatedEncoding = enableFoveatedEncoding
        self.useFullRange = useFullRange
        self.encodingGamma = encodingGamma
        self.maximumBufferingFrames = maximumBufferingFrames
        self.bufferingHistoryWeight = bufferingHistoryWeight
        self.enableHDR = enableHDR
    }

    public let enableHDR: Bool
}

/// How far ahead the ALVR client predicts controller poses.
public enum ControllerPrediction: String, CaseIterable, Sendable {
    /// The same horizon as the head (the measured pipeline latency).
    case full
    /// ALVR's default: `steamvr_pipeline_frames` less than the head.
    case alvr
}

/// Encodes ALVR v20's bincode `StreamConfigPacket`: two UTF-8 strings,
/// each represented by a little-endian u64 byte length followed by bytes.
public enum AlvrStreamConfigEncoder {
    /// `controllerPrediction` `.full` sends
    /// `headset.controllers.content.steamvr_pipeline_frames = 0`. The ALVR
    /// client predicts controllers `steamvr_pipeline_frames` frames (default
    /// 3.0 in v20.11, 2.1 in v20.14) less than the head, because SteamVR is
    /// expected to extrapolate the rest; Basalt's runtime does not, so with the
    /// ALVR default the controllers lag the head by 2–3 frames.
    ///
    /// `codec` is sent as `video.preferred_codec`, as the stock server's full
    /// session settings carry it. The v20 client takes the codec that it
    /// decodes from each `DecoderConfig` packet, not from this field.
    public static func payload(settings: AlvrNegotiatedSettings, wired: Bool = false,
                               controllerPrediction: ControllerPrediction = .full,
                               codec: VideoCodec = .h264) throws -> Data {
        // ALVR v20's fuzzy merge requires the session_settings key. These
        // values come from the selected, explicit latency preset; balanced is
        // the validated baseline and low trims only 0.2 buffered frame.
        var sessionSettings: [String: Any] = [
            "video": [
                "max_buffering_frames": settings.maximumBufferingFrames,
                "buffering_history_weight": settings.bufferingHistoryWeight,
                // A session-JSON Choice is {"variant": name}
                // (`alvr/session/src/lib.rs`).
                "preferred_codec": ["variant": codec.alvrVariantName],
            ],
        ]
        if controllerPrediction == .full {
            // Partial JSON: the client merges it onto its own defaults, and a
            // Switch without "enabled" keeps the default (enabled).
            sessionSettings["headset"] = [
                "controllers": ["content": ["steamvr_pipeline_frames": 0.0]],
            ]
        }
        let sessionObject: [String: Any] = ["session_settings": sessionSettings]
        let session = try JSONSerialization.data(withJSONObject: sessionObject,
                                                  options: [.sortedKeys])
        let negotiatedObject: [String: Any] = [
            "view_resolution": [settings.width, settings.height],
            "refresh_rate_hint": settings.refreshRate,
            "game_audio_sample_rate": settings.gameAudioSampleRate,
            "enable_foveated_encoding": settings.enableFoveatedEncoding,
            "use_multimodal_protocol": false,
            "use_full_range": settings.useFullRange,
            "encoding_gamma": settings.encodingGamma,
            "enable_hdr": settings.enableHDR,
            "wired": wired,
        ]
        let negotiated = try JSONSerialization.data(withJSONObject: negotiatedObject,
                                                     options: [.sortedKeys])
        var payload = Data()
        appendBincodeString(session, to: &payload)
        appendBincodeString(negotiated, to: &payload)
        return payload
    }

    public static func framedPacket(settings: AlvrNegotiatedSettings,
                                    wired: Bool = false,
                                    controllerPrediction: ControllerPrediction = .full,
                                    codec: VideoCodec = .h264)
        throws -> Data {
        let payload = try payload(settings: settings, wired: wired,
                                  controllerPrediction: controllerPrediction, codec: codec)
        guard payload.count <= AlvrControlProbe.maximumPacketBytes else {
            throw BasaltError("ALVR stream configuration is too large")
        }
        var framed = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    private static func appendBincodeString(_ stringData: Data, to output: inout Data) {
        var length = UInt64(stringData.count).littleEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(stringData)
    }
}
