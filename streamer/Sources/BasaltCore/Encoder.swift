import Foundation
import VideoToolbox
import CoreMedia

/// H.264 entropy coding. CABAC compresses better; ALVR's own encoders default
/// to CAVLC. The Quest decode-time effect is a headset A/B measurement.
public enum H264EntropyMode: String, CaseIterable, Sendable {
    case cabac
    case cavlc

    var videoToolboxValue: CFString {
        switch self {
        case .cabac: return kVTH264EntropyMode_CABAC
        case .cavlc: return kVTH264EntropyMode_CAVLC
        }
    }
}

/// The video codec of the stream. ALVR v20's `CodecType` numbers them
/// `H264 = 0, Hevc = 1, AV1 = 2` (`alvr/session/src/settings.rs`); the M3 has
/// no AV1 hardware encoder, so Basalt offers the first two.
public enum VideoCodec: String, CaseIterable, Sendable {
    case h264
    /// HEVC Main (8-bit 4:2:0), as ALVR's servers encode it when
    /// `use_10bit` is off (the default).
    case hevc

    /// The `CodecType` value in ALVR's `DecoderConfig` packet.
    public var alvrCodecType: UInt32 {
        switch self {
        case .h264: return 0
        case .hevc: return 1
        }
    }

    /// The `CodecType` variant name in ALVR's session JSON.
    public var alvrVariantName: String {
        switch self {
        case .h264: return "H264"
        case .hevc: return "Hevc"
        }
    }

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    /// The raw elementary-stream format name for ffmpeg, ffplay, and ffprobe.
    public var ffmpegFormat: String {
        switch self {
        case .h264: return "h264"
        case .hevc: return "hevc"
        }
    }

    var videoToolboxCodecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    /// The NAL unit type of an Annex-B NAL unit, given its first header byte.
    /// H.264 has a 1-byte header (type in the low 5 bits); HEVC has a 2-byte
    /// header (type in bits 1–6 of the first byte).
    public func nalUnitType(headerByte: UInt8) -> UInt8 {
        switch self {
        case .h264: return headerByte & 0x1F
        case .hevc: return (headerByte >> 1) & 0x3F
        }
    }

    /// Parameter-set NAL types, in the order a decoder needs them:
    /// SPS 7, PPS 8 (H.264); VPS 32, SPS 33, PPS 34 (HEVC).
    public var parameterSetNALTypes: [UInt8] {
        switch self {
        case .h264: return [7, 8]
        case .hevc: return [32, 33, 34]
        }
    }
}

/// Hardware H.264 or HEVC encoder built on VideoToolbox, configured for
/// low-latency frame-in/frame-out operation (the same mode MoltenVR
/// advertises).
///
/// Output is an Annex-B byte stream (start-code delimited; parameter sets —
/// SPS/PPS for H.264, VPS/SPS/PPS for HEVC — injected before every keyframe)
/// so any standard decoder — ffplay, the ALVR client's MediaCodec,
/// VideoToolbox on the other end — can consume it.
public final class VideoEncoder {
    public typealias Output = (_ annexB: Data, _ isKeyframe: Bool, _ capturePTS: CMTime) -> Void

    private let session: VTCompressionSession
    private let output: Output
    private let lock = NSLock()
    private var forceKeyframeFlag = false
    private var framesInFlight = 0
    private var averageBitrate: Int
    private let maximumFramesInFlight = 2

    /// Encoding failures are asynchronous and cannot be thrown from `encode`.
    public var onError: ((Error) -> Void)?

    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    /// Called once per submitted frame when VideoToolbox finishes with it:
    /// the submit-to-output time, and whether the encoder dropped the frame
    /// instead of producing output. Low-latency rate control drops whole
    /// frames when the content does not fit the bitrate target, so this
    /// counter is how such drops become visible.
    public var onFrameEncoded: ((_ durationNanoseconds: UInt64, _ droppedByEncoder: Bool) -> Void)?

    /// Session properties that VideoToolbox refused when the session was
    /// configured (for example, low-latency mode does not support
    /// MaxFrameDelayCount on macOS 26). The session still works without them.
    public private(set) var rejectedProperties: [String] = []

    public let codec: VideoCodec

    public init(width: Int, height: Int, fps: Int, bitrate: Int,
        keyframeIntervalSeconds: Int = 2,
        codec: VideoCodec = .h264,
        entropyMode: H264EntropyMode = .cabac,
        output: @escaping Output) throws {
        self.output = output
        self.codec = codec
        averageBitrate = bitrate

        // Low-latency rate control disables lookahead and B-frames. Basalt
        // separately bounds the submission pipeline to two frames. HEVC must
        // be the hardware encoder: a software HEVC fallback cannot keep up
        // with a headset stream, so failing at startup is better.
        var specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ]
        if codec == .hevc {
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] =
                kCFBooleanTrue as Any
        }
        let spec = specification as CFDictionary

        var maybeSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.videoToolboxCodecType,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &maybeSession)
        guard status == noErr, let session = maybeSession else {
            throw BasaltError(
                "VTCompressionSessionCreate failed for \(codec.displayName) (\(status))")
        }
        self.session = session

        // Individual property failures are non-fatal (low-latency mode
        // rejects some keys on some OS versions); best-effort configure, but
        // remember what was refused so the startup log can say so.
        var rejected = [String]()
        func set(_ key: CFString, _ value: CFTypeRef, _ name: String) {
            if VTSessionSetProperty(session, key: key, value: value) != noErr {
                rejected.append(name)
            }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime")
        switch codec {
        case .h264:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel,
                "ProfileLevel")
            set(kVTCompressionPropertyKey_H264EntropyMode, entropyMode.videoToolboxValue,
                "H264EntropyMode")
        case .hevc:
            // Main: 8-bit 4:2:0, what ALVR's servers send unless 10-bit is
            // enabled. HEVC has no entropy choice (always CABAC).
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel,
                "ProfileLevel")
        }
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse,
            "AllowFrameReordering")
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 1),
            "MaxFrameDelayCount")
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue,
            "PrioritizeEncodingSpeedOverQuality")
        if Self.configureBitrate(session, bitrate: bitrate) != noErr {
            rejected.append("AverageBitRate")
        }
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps),
            "ExpectedFrameRate")
        let keyframeSeconds = max(1, keyframeIntervalSeconds)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval,
            NSNumber(value: fps * keyframeSeconds), "MaxKeyFrameInterval")
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            NSNumber(value: keyframeSeconds), "MaxKeyFrameIntervalDuration")
        rejectedProperties = rejected
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Forces every submitted frame out of the encoder. Adds latency, so the
    /// streaming path never calls this; tests use it for deterministic
    /// frame-in/frame-out behavior regardless of VideoToolbox's internal
    /// frame delay.
    public func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    /// Request that the next encoded frame be an IDR keyframe (used when a
    /// new client connects so it can start decoding immediately).
    public func forceKeyframe() {
        lock.lock()
        forceKeyframeFlag = true
        lock.unlock()
    }

    /// VideoToolbox supports changing its rate target while a session is
    /// running. Wireless feedback uses this to shed load without tearing down
    /// the OpenXR or ALVR session.
    @discardableResult
    public func updateAverageBitrate(_ bitrate: Int) -> Bool {
        guard bitrate > 0 else { return false }
        lock.lock()
        guard bitrate != averageBitrate else {
            lock.unlock()
            return true
        }
        averageBitrate = bitrate
        lock.unlock()
        let status = Self.configureBitrate(session, bitrate: bitrate)
        if status != noErr {
            reportError("Could not update VideoToolbox bitrate", status: status)
            return false
        }
        return true
    }

    public var canAcceptFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return framesInFlight < maximumFramesInFlight
    }

    /// Uses the Quest clock as VideoToolbox's per-frame metadata carrier in
    /// runtime mode. With frame reordering disabled, the identical PTS is
    /// returned alongside the corresponding encoded access unit.
    public static func presentationTime(
        questTrackingTimestampNanoseconds timestamp: UInt64
    ) -> CMTime? {
        guard timestamp <= UInt64(Int64.max) else { return nil }
        return CMTime(value: Int64(timestamp), timescale: 1_000_000_000)
    }

    public static func questTrackingTimestampNanoseconds(from presentationTime: CMTime)
        -> UInt64? {
        guard presentationTime.isNumeric, presentationTime.value >= 0 else { return nil }
        let nanoseconds = CMTimeConvertScale(
            presentationTime, timescale: 1_000_000_000, method: .default)
        guard nanoseconds.isNumeric, nanoseconds.value >= 0 else { return nil }
        return UInt64(nanoseconds.value)
    }

    /// Submits a frame if one of two bounded encoder slots is available.
    /// Callers should drop new frames when both are occupied rather than
    /// build a latency queue.
    ///
    /// `completion` runs exactly once: after VideoToolbox finishes with
    /// `pixelBuffer`, or immediately when the frame is rejected.
    @discardableResult
    public func encode(
        _ pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        completion: (@Sendable () -> Void)? = nil
    ) -> Bool {
        lock.lock()
        guard framesInFlight < maximumFramesInFlight else {
            lock.unlock()
            completion?()
            return false
        }
        framesInFlight += 1
        let force = forceKeyframeFlag
        forceKeyframeFlag = false
        lock.unlock()

        let frameProperties: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil

        var infoFlags = VTEncodeInfoFlags()
        let submittedAt = DispatchTime.now().uptimeNanoseconds
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: &infoFlags) { [weak self] status, infoFlags, sampleBuffer in
                guard let self else {
                    completion?()
                    return
                }
                let dropped = status == noErr
                    && (infoFlags.contains(.frameDropped) || sampleBuffer == nil)
                self.lock.lock()
                self.framesInFlight -= 1
                // A forced IDR that rate control dropped must not be lost:
                // the headset asked for it to recover, so the next frame
                // carries the request instead.
                if force && (dropped || status != noErr) { self.forceKeyframeFlag = true }
                self.lock.unlock()
                self.onFrameEncoded?(
                    DispatchTime.now().uptimeNanoseconds &- submittedAt, dropped)

                if status != noErr {
                    self.reportError("VideoToolbox encode callback failed", status: status)
                    completion?()
                    return
                }
                if !dropped, let sampleBuffer {
                    self.emit(sampleBuffer)
                }
                completion?()
            }
        guard status == noErr else {
            lock.lock()
            framesInFlight -= 1
            if force { forceKeyframeFlag = true }
            lock.unlock()
            reportError("VTCompressionSessionEncodeFrame failed", status: status)
            completion?()
            return false
        }
        return true
    }

    private func reportError(_ context: String, status: OSStatus) {
        onError?(BasaltError("\(context) (\(status))"))
    }

    @discardableResult
    private static func configureBitrate(
        _ session: VTCompressionSession, bitrate: Int
    ) -> OSStatus {
        let averageStatus = VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrate))
        // AverageBitRate alone permits very large transient IDRs. A one-second
        // data-rate ceiling still allows recovery frames while preventing
        // them from monopolizing a marginal Wi-Fi queue.
        let bytesPerSecond = max(1, bitrate / 8 * 5 / 4)
        _ = VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_DataRateLimits,
            value: [NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray)
        return averageStatus
    }

    // MARK: AVCC → Annex-B

    /// Rewrites AVCC framing ([4-byte big-endian length][NALU]...) as
    /// Annex-B (start-code delimited). Slice-safe; stops at the first
    /// malformed length instead of reading out of bounds.
    public static func annexB(fromAVCC raw: Data) -> Data {
        var annexB = Data()
        var offset = raw.startIndex
        while offset + 4 <= raw.endIndex {
            let naluLength = raw[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard naluLength > 0, offset + naluLength <= raw.endIndex else { break }
            annexB.append(startCode)
            annexB.append(raw[offset..<offset + naluLength])
            offset += naluLength
        }
        return annexB
    }

    // MARK: Parameter sets

    /// The parameter sets of a VideoToolbox format description, in stored
    /// order: SPS, PPS (H.264) or VPS, SPS, PPS (HEVC). Other NAL units that
    /// an `hvcC` record can carry (SEI) are skipped, because the ALVR
    /// decoder configuration holds only parameter sets.
    public static func parameterSets(of format: CMFormatDescription,
                                     codec: VideoCodec) -> [Data] {
        func get(_ index: Int, _ pointer: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
                 _ size: UnsafeMutablePointer<Int>?,
                 _ count: UnsafeMutablePointer<Int>?) -> OSStatus {
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: pointer,
                    parameterSetSizeOut: size, parameterSetCountOut: count,
                    nalUnitHeaderLengthOut: nil)
            case .hevc:
                return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: pointer,
                    parameterSetSizeOut: size, parameterSetCountOut: count,
                    nalUnitHeaderLengthOut: nil)
            }
        }
        var count = 0
        guard get(0, nil, nil, &count) == noErr else { return [] }
        var sets = [Data]()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard get(index, &pointer, &size, nil) == noErr, let pointer, size > 0,
                  codec.parameterSetNALTypes.contains(
                      codec.nalUnitType(headerByte: pointer.pointee)) else { continue }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }

    /// Annex-B framing of parameter sets: a 4-byte start code before each.
    public static func annexB(parameterSets: [Data]) -> Data {
        var annexB = Data()
        for parameterSet in parameterSets where !parameterSet.isEmpty {
            annexB.append(startCode)
            annexB.append(parameterSet)
        }
        return annexB
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        let notSync = (CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: true) as? [[String: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let isKeyframe = !notSync

        var annexB = Data()

        // Keyframes must be preceded by the parameter sets so a decoder can
        // join mid-stream.
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            annexB.append(Self.annexB(parameterSets: Self.parameterSets(of: format, codec: codec)))
        }

        // VideoToolbox emits AVCC framing; rewrite as Annex-B.
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        // Empty Data has no base address; the copy below would trap.
        guard totalLength > 0 else { return }
        var raw = Data(count: totalLength)
        let copyStatus = raw.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength,
                                       destination: buffer.baseAddress!)
        }
        guard copyStatus == noErr else { return }
        annexB.append(Self.annexB(fromAVCC: raw))

        guard !annexB.isEmpty else { return }
        output(annexB, isKeyframe, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

/// The encoder was H.264-only before HEVC support; the old name still works.
public typealias H264Encoder = VideoEncoder
