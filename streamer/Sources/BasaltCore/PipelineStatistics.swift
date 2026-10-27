import Foundation

/// Per-interval counters for the stages between the Quest tracking uplink and
/// the video socket. The existing transport and Quest lines say *that* frames
/// went missing; these counters say *where*: no fresh tracking, the runtime
/// submitting untracked frames, a busy compositor or encoder, VideoToolbox
/// rate control dropping a frame, or the socket refusing one.
///
/// All `record` methods are thread-safe and cheap. `snapshot(now:)` returns the
/// interval's values and starts the next interval. Times are Mac uptime
/// nanoseconds, so tracking gaps and pose ages never mix the Quest clock with
/// the Mac clock.
public final class PipelineStatistics: @unchecked Sendable {
    public enum DropStage: Sendable {
        /// Both encoder slots were busy when a runtime/capture frame arrived.
        case encoderBusy
        /// The Metal stereo composer was still working on the previous frame.
        case compositorBusy
        /// The encoded access unit could not be handed to the video socket.
        /// This breaks the headset's reference chain and costs an IDR.
        case network
        /// The video socket was still busy, so the frame was not encoded.
        /// The reference chain stays intact.
        case networkBusy
        /// An encoded P-frame was discarded (or a frame not encoded) while
        /// waiting for a recovery IDR after a loss.
        case awaitingIDR
    }

    public struct Snapshot: Equatable, Sendable {
        /// Seconds since this statistics object was created.
        public var elapsedSeconds: Double
        /// Length of the interval the counts below cover.
        public var intervalSeconds: Double
        public var trackingPackets: Int
        /// Longest Mac-side gap between two tracking packets, in the interval.
        /// Nil when fewer than two packets arrived since the object started.
        public var trackingMaximumGapMilliseconds: Double?
        /// Tracking packets whose Quest timestamp was older than the previous
        /// one. The runtime ignores those head poses.
        public var trackingBackwardTimestamps: Int
        public var runtimeFrames: Int
        /// Runtime frames whose views were located without a fresh head pose
        /// (tracking timestamp 0). The Quest cannot match those to a pose.
        public var runtimeUntrackedFrames: Int
        /// Runtime frames that reused the previous frame's tracking timestamp.
        public var runtimeRepeatedTimestamps: Int
        public var encoderBusyDrops: Int
        public var compositorBusyDrops: Int
        public var networkDrops: Int
        public var networkBusyDrops: Int
        public var awaitingIDRDrops: Int
        public var encodedFrames: Int
        public var encoderDroppedFrames: Int
        public var encodeAverageMilliseconds: Double?
        public var encodeMaximumMilliseconds: Double?
        /// Mac-side time from tracking-packet arrival to the moment the video
        /// frame rendered with that pose finished entering the socket.
        public var poseAgeAverageMilliseconds: Double?
        public var poseAgeMaximumMilliseconds: Double?

        public init(elapsedSeconds: Double = 0, intervalSeconds: Double = 0,
                    trackingPackets: Int = 0, trackingMaximumGapMilliseconds: Double? = nil,
                    trackingBackwardTimestamps: Int = 0, runtimeFrames: Int = 0,
                    runtimeUntrackedFrames: Int = 0, runtimeRepeatedTimestamps: Int = 0,
                    encoderBusyDrops: Int = 0, compositorBusyDrops: Int = 0,
                    networkDrops: Int = 0, networkBusyDrops: Int = 0,
                    awaitingIDRDrops: Int = 0, encodedFrames: Int = 0,
                    encoderDroppedFrames: Int = 0,
                    encodeAverageMilliseconds: Double? = nil,
                    encodeMaximumMilliseconds: Double? = nil,
                    poseAgeAverageMilliseconds: Double? = nil,
                    poseAgeMaximumMilliseconds: Double? = nil) {
            self.elapsedSeconds = elapsedSeconds
            self.intervalSeconds = intervalSeconds
            self.trackingPackets = trackingPackets
            self.trackingMaximumGapMilliseconds = trackingMaximumGapMilliseconds
            self.trackingBackwardTimestamps = trackingBackwardTimestamps
            self.runtimeFrames = runtimeFrames
            self.runtimeUntrackedFrames = runtimeUntrackedFrames
            self.runtimeRepeatedTimestamps = runtimeRepeatedTimestamps
            self.encoderBusyDrops = encoderBusyDrops
            self.compositorBusyDrops = compositorBusyDrops
            self.networkDrops = networkDrops
            self.networkBusyDrops = networkBusyDrops
            self.awaitingIDRDrops = awaitingIDRDrops
            self.encodedFrames = encodedFrames
            self.encoderDroppedFrames = encoderDroppedFrames
            self.encodeAverageMilliseconds = encodeAverageMilliseconds
            self.encodeMaximumMilliseconds = encodeMaximumMilliseconds
            self.poseAgeAverageMilliseconds = poseAgeAverageMilliseconds
            self.poseAgeMaximumMilliseconds = poseAgeMaximumMilliseconds
        }
    }

    private let lock = NSLock()
    private let startNanoseconds: UInt64
    private var intervalStartNanoseconds: UInt64
    private var current = Snapshot()
    private var lastTrackingArrival: UInt64?
    private var lastTrackingTimestamp: UInt64?
    private var maximumTrackingGap: UInt64?
    private var lastRuntimeTimestamp: UInt64?
    private var encodeTotal: UInt64 = 0
    private var encodeMaximum: UInt64 = 0
    private var encodeSamples = 0
    private var poseAgeTotal: UInt64 = 0
    private var poseAgeMaximum: UInt64 = 0
    private var poseAgeSamples = 0

    public init(nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        startNanoseconds = nowNanoseconds
        intervalStartNanoseconds = nowNanoseconds
    }

    public func recordTracking(
        timestampNanoseconds: UInt64,
        arrivalNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lock.lock()
        defer { lock.unlock() }
        current.trackingPackets += 1
        if let last = lastTrackingArrival, arrivalNanoseconds >= last {
            maximumTrackingGap = max(maximumTrackingGap ?? 0, arrivalNanoseconds - last)
        }
        if let last = lastTrackingTimestamp, timestampNanoseconds < last {
            current.trackingBackwardTimestamps += 1
        }
        lastTrackingArrival = arrivalNanoseconds
        lastTrackingTimestamp = timestampNanoseconds
    }

    public func recordRuntimeFrame(trackingTimestampNanoseconds timestamp: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        current.runtimeFrames += 1
        if timestamp == 0 {
            current.runtimeUntrackedFrames += 1
        } else if timestamp == lastRuntimeTimestamp {
            current.runtimeRepeatedTimestamps += 1
        }
        lastRuntimeTimestamp = timestamp
    }

    public func recordDrop(_ stage: DropStage) {
        lock.lock()
        defer { lock.unlock() }
        switch stage {
        case .encoderBusy: current.encoderBusyDrops += 1
        case .compositorBusy: current.compositorBusyDrops += 1
        case .network: current.networkDrops += 1
        case .networkBusy: current.networkBusyDrops += 1
        case .awaitingIDR: current.awaitingIDRDrops += 1
        }
    }

    public func recordEncode(durationNanoseconds: UInt64, droppedByEncoder: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if droppedByEncoder {
            current.encoderDroppedFrames += 1
            return
        }
        current.encodedFrames += 1
        encodeTotal &+= durationNanoseconds
        encodeMaximum = max(encodeMaximum, durationNanoseconds)
        encodeSamples += 1
    }

    public func recordPoseAge(nanoseconds: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        poseAgeTotal &+= nanoseconds
        poseAgeMaximum = max(poseAgeMaximum, nanoseconds)
        poseAgeSamples += 1
    }

    /// Returns the finished interval and starts a new one.
    public func snapshot(
        nowNanoseconds now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var result = current
        result.elapsedSeconds = Double(now &- startNanoseconds) / 1_000_000_000
        result.intervalSeconds = Double(now &- intervalStartNanoseconds) / 1_000_000_000
        // A tracking stall that is still in progress is the gap that matters
        // most, so the open gap up to `now` counts as well.
        if let last = lastTrackingArrival, now >= last {
            let openGap = now - last
            result.trackingMaximumGapMilliseconds =
                Double(max(maximumTrackingGap ?? 0, openGap)) / 1_000_000
        }
        if encodeSamples > 0 {
            result.encodeAverageMilliseconds =
                Double(encodeTotal) / Double(encodeSamples) / 1_000_000
            result.encodeMaximumMilliseconds = Double(encodeMaximum) / 1_000_000
        }
        if poseAgeSamples > 0 {
            result.poseAgeAverageMilliseconds =
                Double(poseAgeTotal) / Double(poseAgeSamples) / 1_000_000
            result.poseAgeMaximumMilliseconds = Double(poseAgeMaximum) / 1_000_000
        }
        current = Snapshot()
        intervalStartNanoseconds = now
        maximumTrackingGap = nil
        encodeTotal = 0
        encodeMaximum = 0
        encodeSamples = 0
        poseAgeTotal = 0
        poseAgeMaximum = 0
        poseAgeSamples = 0
        return result
    }
}

/// Remembers when recent Quest tracking timestamps arrived on the Mac, so a
/// video frame carrying one of them can report how old its pose is.
public struct TrackingArrivalHistory: Sendable {
    public static let defaultCapacity = 512
    private var timestamps: [UInt64]
    private var arrivals: [UInt64]
    private var next = 0
    private var count = 0

    public init(capacity: Int = defaultCapacity) {
        timestamps = Array(repeating: 0, count: max(1, capacity))
        arrivals = Array(repeating: 0, count: max(1, capacity))
    }

    public mutating func record(timestampNanoseconds: UInt64, arrivalNanoseconds: UInt64) {
        timestamps[next] = timestampNanoseconds
        arrivals[next] = arrivalNanoseconds
        next = (next + 1) % timestamps.count
        count = min(count + 1, timestamps.count)
    }

    /// The arrival time of the newest entry with this timestamp, or nil.
    public func arrival(ofTimestamp timestamp: UInt64) -> UInt64? {
        guard timestamp != 0 else { return nil }
        for offset in 0..<count {
            let index = (next - 1 - offset + timestamps.count) % timestamps.count
            if timestamps[index] == timestamp { return arrivals[index] }
        }
        return nil
    }
}
