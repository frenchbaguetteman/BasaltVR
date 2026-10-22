import Foundation

/// Decides what video to send while an ALVR client is attached but the
/// OpenXR runtime submits nothing (a slow game, a hitch, loading, between
/// sessions, or not started yet).
///
/// What the ALVR v20.14.1 client does without new video (checked in its
/// source): nothing breaks. The video receive loop only retries
/// (`client_core/src/connection.rs`, `STREAMING_RECV_TIMEOUT`); the session
/// times out only on the *control* channel (`KEEPALIVE_TIMEOUT`). The
/// renderer keeps the last decoded picture and draws it with the pose of
/// that picture (`client_openxr/src/stream.rs`, `last_good_view_params`), so
/// the headset shows the last game image, world-locked. Therefore:
///
/// - **After a real frame**, the filler does *not* stream anything. It
///   re-sends the last composed game image only when the headset does not
///   have it: the image was never delivered (transport busy, encoder busy,
///   rate-control drop), or the reference chain broke (a lost access unit,
///   a Quest IDR request, a new session). The repeat carries the real
///   frame's Quest tracking timestamp, so the client finds that frame's head
///   pose and reprojects it correctly. The client keeps only the newest 1024
///   head poses, polled at 3x the display rate (2.8 s at 120 Hz), so a
///   repeat is sent only while the image is younger than
///   `poseWindowNanoseconds`; after that the client's own copy (correct
///   pose) is better than a re-send that it would place at a default pose.
/// - **Before the first real frame** (game loading) and **after the runtime
///   disconnected or a new game session replaced the old one**, the filler
///   sends a black frame until one black picture has been delivered on an
///   intact chain. Black frames carry the newest tracking timestamp.
///
/// Encoder time must not run backwards. A repeat therefore gets a
/// presentation time just after the previous filler frame (nanoseconds after
/// the real frame's timestamp); `videoTimestamp(forPresentationNanoseconds:)`
/// maps it back to the real frame's tracking timestamp for the ALVR header.
/// A runtime frame whose timestamp is not newer than the last filler frame
/// is refused.
///
/// Filler frames are tried only after `idleThresholdNanoseconds` without a
/// runtime frame, and at most once per `intervalNanoseconds`. A game at
/// 30-60 fps delivers a frame every 17-33 ms, far below the 0.5 s threshold,
/// so it never gets a filler frame.
///
/// `Image` is the retained composed frame (in the streamer, a
/// `RuntimeStereoComposer.ComposedFrame`). Thread-safe.
public final class RuntimeIdleVideoFiller<Image>: @unchecked Sendable {
    public enum Frame {
        /// Encode the black frame; the presentation time and the ALVR
        /// timestamp are both the newest Quest tracking timestamp.
        case black(trackingTimestampNanoseconds: UInt64)
        /// Encode `image` (the last composed game frame) again.
        case repeatLast(Image, trackingTimestampNanoseconds: UInt64,
                        presentationNanoseconds: UInt64)

        public var presentationNanoseconds: UInt64 {
            switch self {
            case .black(let timestamp): return timestamp
            case .repeatLast(_, _, let presentation): return presentation
            }
        }

        public var trackingTimestampNanoseconds: UInt64 {
            switch self {
            case .black(let timestamp): return timestamp
            case .repeatLast(_, let timestamp, _): return timestamp
            }
        }

        public var isRepeat: Bool {
            if case .repeatLast = self { return true }
            return false
        }
    }

    public static var defaultIdleThresholdNanoseconds: UInt64 { 500_000_000 }
    public static var defaultIntervalNanoseconds: UInt64 { 100_000_000 }
    /// Below the client's 1024-pose history at 120 Hz (1024 / 360 Hz = 2.8 s).
    public static var defaultPoseWindowNanoseconds: UInt64 { 2_000_000_000 }

    public let idleThresholdNanoseconds: UInt64
    public let intervalNanoseconds: UInt64
    public let poseWindowNanoseconds: UInt64

    private struct HeldFrame {
        let image: Image
        let trackingTimestamp: UInt64
    }

    private let lock = NSLock()
    private var lastRuntimeFrameNanoseconds: UInt64?
    private var newestRuntimeTimestamp: UInt64?
    private var lastFillerNanoseconds: UInt64?
    /// Presentation time of the newest filler frame handed out.
    private var lastFillerPresentation: UInt64?
    private var held: HeldFrame?
    /// Newest ALVR timestamp the headset received on the current chain.
    private var deliveredTimestamp: UInt64?
    /// First black frame handed out since the held frame was discarded.
    private var firstBlackTimestamp: UInt64?
    /// Repeat presentation time -> the real frame's tracking timestamp.
    private var repeatTimestamps: [UInt64: UInt64] = [:]

    public init(idleThresholdNanoseconds: UInt64 = defaultIdleThresholdNanoseconds,
                intervalNanoseconds: UInt64 = defaultIntervalNanoseconds,
                poseWindowNanoseconds: UInt64 = defaultPoseWindowNanoseconds) {
        self.idleThresholdNanoseconds = idleThresholdNanoseconds
        self.intervalNanoseconds = intervalNanoseconds
        self.poseWindowNanoseconds = poseWindowNanoseconds
    }

    /// Records a runtime frame and says whether it may be encoded.
    public func admitRuntimeFrame(trackingTimestampNanoseconds timestamp: UInt64,
                                  now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lastRuntimeFrameNanoseconds = now
        if let lastFillerPresentation, timestamp <= lastFillerPresentation {
            return false
        }
        newestRuntimeTimestamp = max(newestRuntimeTimestamp ?? 0, timestamp)
        return true
    }

    /// Keeps the newest composed game frame for repeats. An older frame
    /// (completions racing) is ignored.
    public func holdComposedFrame(_ image: Image, trackingTimestampNanoseconds timestamp: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if let held, timestamp <= held.trackingTimestamp { return }
        held = HeldFrame(image: image, trackingTimestamp: timestamp)
        firstBlackTimestamp = nil
    }

    /// The runtime disconnected, a new game session replaced the old one, or
    /// the headset session ended: the last image no longer belongs on the
    /// headset. Black is sent until the next real frame.
    public func discardHeldFrame() {
        lock.lock()
        defer { lock.unlock() }
        held = nil
        deliveredTimestamp = nil
        firstBlackTimestamp = nil
        repeatTimestamps.removeAll()
    }

    public var hasHeldFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held != nil
    }

    /// Returns the filler frame to encode now, if one is due, and records it.
    /// - Parameter referenceChainBroken: the loss-recovery gate waits for an
    ///   IDR (`VideoLossRecoveryGate.isAwaitingIDR`), so the headset may show
    ///   nothing or a damaged picture.
    public func nextFrame(now: UInt64 = DispatchTime.now().uptimeNanoseconds,
                          latestTrackingTimestamp: UInt64?,
                          hasStream: Bool,
                          referenceChainBroken: Bool) -> Frame? {
        guard hasStream, let latest = latestTrackingTimestamp, latest > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let lastRuntimeFrameNanoseconds,
           now &- lastRuntimeFrameNanoseconds < idleThresholdNanoseconds {
            return nil
        }
        if let lastFillerNanoseconds, now &- lastFillerNanoseconds < intervalNanoseconds {
            return nil
        }
        if let held {
            let timestamp = held.trackingTimestamp
            let delivered = (deliveredTimestamp ?? 0) >= timestamp
            guard referenceChainBroken || !delivered else { return nil }
            // The client would no longer find this frame's head pose.
            guard latest <= timestamp || latest - timestamp <= poseWindowNanoseconds else {
                return nil
            }
            let presentation = max(timestamp, lastFillerPresentation ?? 0) + 1
            lastFillerNanoseconds = now
            lastFillerPresentation = presentation
            repeatTimestamps = repeatTimestamps.filter { $0.value >= timestamp }
            repeatTimestamps[presentation] = timestamp
            return .repeatLast(held.image, trackingTimestampNanoseconds: timestamp,
                               presentationNanoseconds: presentation)
        }
        if let firstBlackTimestamp, !referenceChainBroken,
           (deliveredTimestamp ?? 0) >= firstBlackTimestamp {
            return nil
        }
        // Encoder time must move forward past every frame it has seen.
        if let lastFillerPresentation, latest <= lastFillerPresentation { return nil }
        if let newestRuntimeTimestamp, latest <= newestRuntimeTimestamp { return nil }
        lastFillerNanoseconds = now
        lastFillerPresentation = latest
        if firstBlackTimestamp == nil { firstBlackTimestamp = latest }
        return .black(trackingTimestampNanoseconds: latest)
    }

    /// The Quest tracking timestamp to put in the ALVR video header for an
    /// encoded access unit with this presentation time.
    public func videoTimestamp(forPresentationNanoseconds presentation: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return repeatTimestamps[presentation] ?? presentation
    }

    /// The access unit with this presentation time reached the headset.
    public func recordDelivered(presentationNanoseconds presentation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = repeatTimestamps[presentation] ?? presentation
        deliveredTimestamp = max(deliveredTimestamp ?? 0, timestamp)
    }
}
