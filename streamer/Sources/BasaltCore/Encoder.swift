import Foundation
import VideoToolbox
import CoreMedia

/// Hardware H.264 encoder built on VideoToolbox, configured for low-latency
/// frame-in/frame-out operation (the same mode MoltenVR advertises).
///
/// Output is Annex-B byte-stream H.264 (start-code delimited, SPS/PPS
/// injected before every keyframe) so any standard decoder — ffplay, the
/// ALVR client's MediaCodec, VideoToolbox on the other end — can consume it.
public final class H264Encoder {
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

    public init(width: Int, height: Int, fps: Int, bitrate: Int,
        output: @escaping Output) throws {
        self.output = output
        averageBitrate = bitrate

        // Low-latency rate control disables lookahead and B-frames. Basalt
        // separately bounds the submission pipeline to two frames.
        let spec = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ] as CFDictionary

        var maybeSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &maybeSession)
        guard status == noErr, let session = maybeSession else {
            throw BasaltError("VTCompressionSessionCreate failed (\(status))")
        }
        self.session = session

        // Individual property failures are non-fatal (low-latency mode
        // rejects some keys on some OS versions); best-effort configure.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode,
                             value: kVTH264EntropyMode_CABAC)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                             value: NSNumber(value: 1))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                             value: kCFBooleanTrue)
        Self.configureBitrate(session, bitrate: bitrate)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: fps * 2))
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
                self.lock.lock()
                self.framesInFlight -= 1
                self.lock.unlock()

                if status != noErr {
                    self.reportError("VideoToolbox encode callback failed", status: status)
                    completion?()
                    return
                }
                if !infoFlags.contains(.frameDropped), let sampleBuffer {
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

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        let notSync = (CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: true) as? [[String: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let isKeyframe = !notSync

        var annexB = Data()

        // Keyframes must be preceded by SPS/PPS so a decoder can join
        // mid-stream.
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var parameterSetCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: nil)
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil) == noErr,
                      let pointer else { continue }
                annexB.append(Self.startCode)
                annexB.append(pointer, count: size)
            }
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
