import Foundation

/// Keeps the H.264 stream that the Quest decodes on an intact reference chain.
///
/// Basalt's SPS sets `gaps_in_frame_num_allowed_flag = 0`. When an encoded
/// reference frame never reaches the headset, every later P-frame skips a
/// `frame_num`; the Quest decoder logs `h264DpbFillFrameNumGap: Frame num gap
/// is not allowed` and shows corrupt pictures until the next IDR.
///
/// Two rules prevent that:
///
/// 1. Drop *before* encoding when possible. A frame that is never submitted
///    does not advance `frame_num`, and neither does a frame that
///    VideoToolbox's rate control drops, so skipping the encode while the
///    transport is busy keeps the chain intact without an IDR.
///    `prepareEncode(transportBusy:)` does this.
/// 2. Once an encoded access unit is lost anyway (network-busy drop, USB
///    stall, Wi-Fi shard loss, a missing tracking timestamp, a client decoder
///    request, or a new session), discard every later P-frame and force an
///    IDR on the next encode. The gate opens again only for an IDR, and the
///    IDR counts as recovered only after the transport has written it
///    completely. There is no one-second throttle on this path; only
///    repeated *client* requests while an IDR is already in flight are
///    ignored.
///
/// Thread-safe. Times are Mac uptime nanoseconds; tests inject the clock.
public final class VideoLossRecoveryGate: @unchecked Sendable {
    public enum EncodeDecision: Equatable, Sendable {
        /// Submit the frame normally.
        case encode
        /// Submit the frame with VideoToolbox's ForceKeyFrame option.
        case encodeKeyframe
        /// The video transport would drop the output: do not encode, so the
        /// reference chain stays intact.
        case skipTransportBusy
        /// A recovery IDR was requested very recently and lost again. Wait
        /// before the next one instead of sending a keyframe storm into a
        /// congested link; any P-frame encoded now would be discarded.
        case skipRecoveryBackoff
    }

    /// Client IDR requests are ignored this long after a recovery IDR was
    /// requested (while it is in flight) or delivered. The Quest repeats
    /// its request until an IDR arrives; ALVR uses 100 ms.
    public static let defaultClientRequestThrottleNanoseconds: UInt64 = 100_000_000

    private let lock = NSLock()
    private let clientRequestThrottleNanoseconds: UInt64
    private let recoveryKeyframeMinimumGapNanoseconds: UInt64
    private let now: @Sendable () -> UInt64

    /// The headset's reference chain is broken: only an IDR may be sent.
    private var awaitingIDR = true
    /// The current recovery episode already asked the encoder for an IDR.
    /// Frames submitted after that request follow the IDR in output order.
    private var keyframeRequested = false
    private var lastRecoveryKeyframeRequest: UInt64?
    /// Set while a recovery IDR is requested but not yet completely sent.
    private var idrPendingSince: UInt64?
    private var lastIDRDelivered: UInt64?

    /// - Parameters:
    ///   - recoveryKeyframeMinimumGapNanoseconds: shortest time between two
    ///     recovery IDRs requested after losses. Zero over USB (TCP does not
    ///     lose data; losses there only come from a busy transport). Wi-Fi
    ///     uses a short gap so a saturated link is not flooded with IDRs.
    public init(
        clientRequestThrottleNanoseconds: UInt64 = defaultClientRequestThrottleNanoseconds,
        recoveryKeyframeMinimumGapNanoseconds: UInt64 = 0,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.clientRequestThrottleNanoseconds = clientRequestThrottleNanoseconds
        self.recoveryKeyframeMinimumGapNanoseconds = recoveryKeyframeMinimumGapNanoseconds
        self.now = now
    }

    /// True while P-frames are being discarded until the next IDR.
    public var isAwaitingIDR: Bool {
        lock.lock()
        defer { lock.unlock() }
        return awaitingIDR
    }

    /// Call right before a frame is submitted to the encoder.
    /// `transportBusy` is true when the video transport would drop a frame
    /// handed to it now (a write still in flight, a failed transport, or no
    /// tracking timestamp to send it with).
    public func prepareEncode(transportBusy: Bool) -> EncodeDecision {
        lock.lock()
        defer { lock.unlock() }
        if transportBusy { return .skipTransportBusy }
        guard awaitingIDR, !keyframeRequested else { return .encode }
        let time = now()
        if let last = lastRecoveryKeyframeRequest,
           time &- last < recoveryKeyframeMinimumGapNanoseconds {
            return .skipRecoveryBackoff
        }
        keyframeRequested = true
        lastRecoveryKeyframeRequest = time
        if idrPendingSince == nil { idrPendingSince = time }
        return .encodeKeyframe
    }

    /// Call for every encoded access unit before it goes to the headset.
    /// Returns false when the unit must be discarded: it is a P-frame that
    /// references a frame the headset never received.
    public func admit(isIDR: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isIDR {
            // Any IDR, including a periodic one, starts a new chain.
            awaitingIDR = false
            keyframeRequested = false
            return true
        }
        return !awaitingIDR
    }

    /// Call when an encoded access unit that `admit` accepted did not reach
    /// the headset completely. Returns true when this starts a new recovery
    /// episode (useful for logging).
    @discardableResult
    public func frameLost() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Already waiting for an IDR that is not yet requested: the same
        // loss reported twice (for example by both the sender and the
        // router) must not cause a second IDR.
        if awaitingIDR && !keyframeRequested { return false }
        let startsEpisode = !awaitingIDR
        awaitingIDR = true
        // The lost unit may be the requested IDR itself; ask again.
        keyframeRequested = false
        if idrPendingSince == nil { idrPendingSince = now() }
        return startsEpisode
    }

    /// Call when the transport has completely written an IDR.
    public func idrDelivered() {
        lock.lock()
        defer { lock.unlock() }
        lastIDRDelivered = now()
        if !awaitingIDR { idrPendingSince = nil }
    }

    /// The Quest asked for an IDR (decoder error or detected packet loss).
    /// Ignored only while a recovery IDR is already in flight or was just
    /// delivered, because the Quest repeats the request until one arrives.
    /// Returns whether the request started a recovery.
    @discardableResult
    public func clientRequestedIDR() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let time = now()
        if let pending = idrPendingSince,
           time &- pending < clientRequestThrottleNanoseconds {
            return false
        }
        if let delivered = lastIDRDelivered,
           time &- delivered < clientRequestThrottleNanoseconds {
            return false
        }
        awaitingIDR = true
        keyframeRequested = false
        idrPendingSince = time
        return true
    }

    /// A new ALVR session (or a reconnect) starts with nothing decoded:
    /// discard P-frames and force an IDR on the next encode, bypassing the
    /// recovery gap.
    public func restart() {
        lock.lock()
        defer { lock.unlock() }
        awaitingIDR = true
        keyframeRequested = false
        lastRecoveryKeyframeRequest = nil
        idrPendingSince = now()
    }
}
