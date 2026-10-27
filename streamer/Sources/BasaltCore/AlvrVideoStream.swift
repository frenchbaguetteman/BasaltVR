import Foundation

public struct AlvrClientStatistics: Equatable, Sendable {
    public let targetTimestampNanoseconds: UInt64
    public let frameIntervalNanoseconds: UInt64
    public let videoDecodeNanoseconds: UInt64
    public let videoDecoderQueueNanoseconds: UInt64
    public let renderingNanoseconds: UInt64
    public let vsyncQueueNanoseconds: UInt64
    public let totalPipelineLatencyNanoseconds: UInt64

    public init(targetTimestampNanoseconds: UInt64,
                frameIntervalNanoseconds: UInt64,
                videoDecodeNanoseconds: UInt64,
                videoDecoderQueueNanoseconds: UInt64,
                renderingNanoseconds: UInt64,
                vsyncQueueNanoseconds: UInt64,
                totalPipelineLatencyNanoseconds: UInt64) {
        self.targetTimestampNanoseconds = targetTimestampNanoseconds
        self.frameIntervalNanoseconds = frameIntervalNanoseconds
        self.videoDecodeNanoseconds = videoDecodeNanoseconds
        self.videoDecoderQueueNanoseconds = videoDecoderQueueNanoseconds
        self.renderingNanoseconds = renderingNanoseconds
        self.vsyncQueueNanoseconds = vsyncQueueNanoseconds
        self.totalPipelineLatencyNanoseconds = totalPipelineLatencyNanoseconds
    }
}

public struct AlvrHeadPose: Equatable, Sendable {
    public let orientationX: Float
    public let orientationY: Float
    public let orientationZ: Float
    public let orientationW: Float
    public let positionX: Float
    public let positionY: Float
    public let positionZ: Float

    public init(orientationX: Float, orientationY: Float, orientationZ: Float,
                orientationW: Float, positionX: Float, positionY: Float,
                positionZ: Float) {
        self.orientationX = orientationX
        self.orientationY = orientationY
        self.orientationZ = orientationZ
        self.orientationW = orientationW
        self.positionX = positionX
        self.positionY = positionY
        self.positionZ = positionZ
    }
}

public enum AlvrHand: UInt32, Equatable, Hashable, Sendable {
    case left = 0
    case right = 1

    public init?(alvrDeviceID: UInt64) {
        switch alvrDeviceID {
        case 0xe521_d8da_be2d_07a2: self = .left
        case 0xf6b8_1330_eb3d_bdd8: self = .right
        default: return nil
        }
    }

    public var alvrDeviceID: UInt64 {
        switch self {
        case .left: 0xe521_d8da_be2d_07a2
        case .right: 0xf6b8_1330_eb3d_bdd8
        }
    }
}

public struct AlvrControllerMotion: Equatable, Sendable {
    public let pose: AlvrHeadPose
    public let linearVelocityX: Float
    public let linearVelocityY: Float
    public let linearVelocityZ: Float
    public let angularVelocityX: Float
    public let angularVelocityY: Float
    public let angularVelocityZ: Float

    public init(pose: AlvrHeadPose,
                linearVelocityX: Float, linearVelocityY: Float,
                linearVelocityZ: Float, angularVelocityX: Float,
                angularVelocityY: Float, angularVelocityZ: Float) {
        self.pose = pose
        self.linearVelocityX = linearVelocityX
        self.linearVelocityY = linearVelocityY
        self.linearVelocityZ = linearVelocityZ
        self.angularVelocityX = angularVelocityX
        self.angularVelocityY = angularVelocityY
        self.angularVelocityZ = angularVelocityZ
    }
}

public enum AlvrUplinkPacket: Equatable, Sendable {
    case tracking(timestampNanoseconds: UInt64, headPose: AlvrHeadPose?,
                  leftController: AlvrControllerMotion?,
                  rightController: AlvrControllerMotion?,
                  controllerMask: UInt32)
    case statistics(AlvrClientStatistics)
    case other(streamID: UInt16)
}

/// Decodes the first/header shard of ALVR's client-to-server streams.
/// Tracking starts with a target timestamp; statistics is a header-only
/// packet containing seven Rust `Duration` values.
public enum AlvrUplinkPacketDecoder {
    private static let prefixSize = 18
    // ALVR v20 hashes these stable OpenXR user paths with Rust's
    // DefaultHasher. Keeping the v20 constants here avoids relying on vector
    // order when only one controller is connected.
    private static let headID: UInt64 = 0x5b90_853d_c920_2538
    private static let leftHandID: UInt64 = 0xe521_d8da_be2d_07a2
    private static let rightHandID: UInt64 = 0xf6b8_1330_eb3d_bdd8
    private static let deviceMotionSize = 8 + 13 * 4

    public static func decode(_ datagram: Data) throws -> AlvrUplinkPacket {
        let bytes = [UInt8](datagram)
        guard bytes.count >= prefixSize else { throw BasaltError("Truncated ALVR uplink shard") }
        let packetLength = Int(bigEndianUInt32(bytes, at: 0)) + 4
        let streamID = bigEndianUInt16(bytes, at: 4)
        let shardCount = bigEndianUInt32(bytes, at: 10)
        let shardIndex = bigEndianUInt32(bytes, at: 14)
        guard packetLength == bytes.count, shardCount > 0, shardIndex < shardCount else {
            throw BasaltError("Invalid ALVR uplink shard header")
        }
        guard shardIndex == 0 else { return .other(streamID: streamID) }

        switch streamID {
        case 0:
            let (timestamp, nextOffset) = try duration(bytes, at: prefixSize)
            let motions = decodeDeviceMotions(bytes, at: nextOffset)
            return .tracking(
                timestampNanoseconds: timestamp,
                headPose: motions.head,
                leftController: motions.left,
                rightController: motions.right,
                controllerMask: motions.controllerMask)
        case 4:
            guard shardCount == 1 else {
                throw BasaltError("Unexpected sharded ALVR statistics packet")
            }
            var offset = prefixSize
            var values = [UInt64]()
            for _ in 0..<7 {
                let decoded = try duration(bytes, at: offset)
                values.append(decoded.nanoseconds)
                offset = decoded.nextOffset
            }
            guard offset == packetLength else {
                throw BasaltError("Unexpected ALVR statistics payload length")
            }
            return .statistics(AlvrClientStatistics(
                targetTimestampNanoseconds: values[0],
                frameIntervalNanoseconds: values[1],
                videoDecodeNanoseconds: values[2],
                videoDecoderQueueNanoseconds: values[3],
                renderingNanoseconds: values[4],
                vsyncQueueNanoseconds: values[5],
                totalPipelineLatencyNanoseconds: values[6]))
        default:
            return .other(streamID: streamID)
        }
    }

    /// `Tracking` starts with a bincode Vec of `(u64, DeviceMotion)` where a
    /// motion is glam Quat(x,y,z,w), Vec3 position, then linear and angular
    /// Vec3 velocities. Unknown body trackers are skipped.
    private static func decodeDeviceMotions(_ bytes: [UInt8], at offset: Int)
        -> (head: AlvrHeadPose?, left: AlvrControllerMotion?,
            right: AlvrControllerMotion?, controllerMask: UInt32) {
        guard offset + 8 <= bytes.count else { return (nil, nil, nil, 0) }
        let motionCount = littleEndianUInt64(bytes, at: offset)
        guard motionCount <= 64 else {
            return (nil, nil, nil, 0)
        }
        // Tracking headers may span ALVR shards when body/skeleton data is
        // enabled. HEAD, left, and right are serialized first, so decode the
        // complete DeviceMotion records present in shard zero without
        // requiring the advertised vector tail to be available yet.
        let availableMotionCount = min(
            Int(motionCount), (bytes.count - offset - 8) / deviceMotionSize)
        var head: AlvrHeadPose?
        var left: AlvrControllerMotion?
        var right: AlvrControllerMotion?
        var controllerMask: UInt32 = 0
        for index in 0..<availableMotionCount {
            let entryOffset = offset + 8 + index * deviceMotionSize
            let deviceID = littleEndianUInt64(bytes, at: entryOffset)
            let valuesOffset = entryOffset + 8
            let values = stride(from: valuesOffset,
                                to: valuesOffset + 13 * 4, by: 4).map {
                Float(bitPattern: littleEndianUInt32(bytes, at: $0))
            }
            guard values.allSatisfy(\.isFinite) else { continue }
            let normSquared = values[0] * values[0] + values[1] * values[1]
                + values[2] * values[2] + values[3] * values[3]
            guard normSquared > 0.5, normSquared < 1.5 else { continue }
            let pose = AlvrHeadPose(
                orientationX: values[0], orientationY: values[1],
                orientationZ: values[2], orientationW: values[3],
                positionX: values[4], positionY: values[5], positionZ: values[6])
            if deviceID == headID {
                head = pose
            } else if deviceID == leftHandID || deviceID == rightHandID {
                let motion = AlvrControllerMotion(
                    pose: pose,
                    linearVelocityX: values[7], linearVelocityY: values[8],
                    linearVelocityZ: values[9], angularVelocityX: values[10],
                    angularVelocityY: values[11], angularVelocityZ: values[12])
                if deviceID == leftHandID {
                    left = motion
                    controllerMask |= 1
                } else {
                    right = motion
                    controllerMask |= 2
                }
            }
        }
        return (head, left, right, controllerMask)
    }

    private static func duration(_ bytes: [UInt8], at offset: Int) throws
        -> (nanoseconds: UInt64, nextOffset: Int) {
        guard offset + 12 <= bytes.count else {
            throw BasaltError("Truncated ALVR duration")
        }
        let seconds = littleEndianUInt64(bytes, at: offset)
        let nanos = littleEndianUInt32(bytes, at: offset + 8)
        guard nanos < 1_000_000_000 else { throw BasaltError("Invalid ALVR duration") }
        let (secondsNanos, overflow1) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (total, overflow2) = secondsNanos.addingReportingOverflow(UInt64(nanos))
        guard !overflow1, !overflow2 else { throw BasaltError("ALVR duration overflow") }
        return (total, offset + 12)
    }

    private static func bigEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func bigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { ($0 << 8) | UInt32(bytes[offset + $1]) }
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | (UInt32(bytes[offset + $1]) << UInt32($1 * 8)) }
    }

    private static func littleEndianUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | (UInt64(bytes[offset + $1]) << UInt64($1 * 8)) }
    }
}

public enum AlvrStreamTransport: String, Sendable {
    case udp
    case tcp
}

/// One completed video access-unit write. The duration starts before ALVR
/// packetization and ends only after every shard has entered the transport.
/// Consumers can aggregate this without instrumenting the realtime encoder.
public struct AlvrVideoSendReport: Equatable, Sendable {
    public let timestampNanoseconds: UInt64
    public let accessUnitBytes: Int
    public let wireBytes: Int
    public let shardCount: Int
    public let isIDR: Bool
    public let durationNanoseconds: UInt64
    /// Mac-side time from the arrival of the tracking packet whose timestamp
    /// this frame carries to the end of this write; nil when that packet is
    /// no longer in the sender's recent history (or the timestamp is 0).
    public let trackingAgeNanoseconds: UInt64?

    public init(timestampNanoseconds: UInt64, accessUnitBytes: Int,
                wireBytes: Int, shardCount: Int, isIDR: Bool,
                durationNanoseconds: UInt64, trackingAgeNanoseconds: UInt64? = nil) {
        self.timestampNanoseconds = timestampNanoseconds
        self.accessUnitBytes = accessUnitBytes
        self.wireBytes = wireBytes
        self.shardCount = shardCount
        self.isIDR = isIDR
        self.durationNanoseconds = durationNanoseconds
        self.trackingAgeNanoseconds = trackingAgeNanoseconds
    }
}

public struct AlvrAudioSendReport: Equatable, Sendable {
    public let pcmBytes: Int
    public let wireBytes: Int
    public let shardCount: Int
    public let durationNanoseconds: UInt64

    public init(pcmBytes: Int, wireBytes: Int, shardCount: Int,
                durationNanoseconds: UInt64) {
        self.pcmBytes = pcmBytes
        self.wireBytes = wireBytes
        self.shardCount = shardCount
        self.durationNanoseconds = durationNanoseconds
    }
}

/// Decides whether a video access unit handed to the sender now is written
/// or dropped. At most one access unit is written and one waits behind it.
///
/// A write in flight only counts as "busy" once it has run longer than
/// `busyAfterNanoseconds` (one frame period at the negotiated refresh rate).
/// A normal write takes 0.3-1.6 ms, and the next frame needs ~11 ms to
/// encode, so dropping it because such a write had just started was needless
/// (0.7-1.7% of frames on an idle link). A longer write is a real stall
/// (a paused USB link, a saturated Wi-Fi queue): frames are then dropped, as
/// before, so stale frames never pile up and `VideoLossRecoveryGate` keeps
/// the reference chain intact. A frame that waits does so for less than one
/// frame period plus the rest of the write, so latency does not grow.
///
/// Not thread-safe; the sender holds its state lock. Times are Mac uptime
/// nanoseconds.
struct AlvrVideoSendAdmission: Sendable {
    /// One access unit written plus one waiting.
    static let maximumOutstanding = 2

    var busyAfterNanoseconds: UInt64
    /// Access units accepted and not yet finished (0, 1, or 2).
    private(set) var outstanding = 0
    /// When the access unit at the head of the queue became the one written.
    private var headSince: UInt64 = 0

    init(busyAfterNanoseconds: UInt64) {
        self.busyAfterNanoseconds = busyAfterNanoseconds
    }

    /// One frame period at `hertz`, or nil for a rate outside 30-240 Hz.
    static func busyAfterNanoseconds(refreshRate hertz: Float) -> UInt64? {
        guard hertz.isFinite, hertz >= 30, hertz <= 240 else { return nil }
        return UInt64((1_000_000_000 / Double(hertz)).rounded())
    }

    /// True when `admit(now:)` would drop an access unit handed over now.
    func wouldDrop(now: UInt64) -> Bool {
        switch outstanding {
        case 0: return false
        case 1: return now &- headSince > busyAfterNanoseconds
        default: return true
        }
    }

    /// Accepts an access unit unless it would be dropped.
    mutating func admit(now: UInt64) -> Bool {
        guard !wouldDrop(now: now) else { return false }
        if outstanding == 0 { headSince = now }
        outstanding += 1
        return true
    }

    /// The access unit at the head of the queue was written (or abandoned).
    mutating func complete(now: UInt64) {
        guard outstanding > 0 else { return }
        outstanding -= 1
        if outstanding > 0 { headSince = now }
    }
}

/// Sends ALVR-sharded H.264 access units over the v20 stream socket. ALVR
/// uses UDP over Wi-Fi and a length-framed TCP byte stream through adb USB
/// forwarding when the negotiated session has `wired` enabled.
public final class AlvrVideoStreamSender: @unchecked Sendable {
    public static let defaultPort: UInt16 = 9944

    public var onError: ((Error) -> Void)?
    public var onFrameDropped: (() -> Void)?
    public var onCongestion: (() -> Void)?
    public var onStatistics: ((AlvrClientStatistics) -> Void)?
    public var onHeadPose: ((_ timestampNanoseconds: UInt64, _ pose: AlvrHeadPose) -> Void)?
    /// Every complete tracking packet (shards joined): controller or hand
    /// motions and hand skeletons. The head pose and timestamp also arrive
    /// earlier, from the first shard, through `onHeadPose` and
    /// `onTrackingTimestamp`.
    public var onTrackingSample: ((AlvrTrackingSample) -> Void)?
    /// Every decoded tracking packet, with or without poses, in arrival order.
    public var onTrackingTimestamp: ((_ timestampNanoseconds: UInt64) -> Void)?
    public var onFrameSent: ((AlvrVideoSendReport) -> Void)?
    public var onAudioSent: ((AlvrAudioSendReport) -> Void)?
    public var onAudioDropped: (() -> Void)?
    /// Called once when the USB TCP stream can no longer carry frames: a
    /// write failed (for example Broken pipe after the Quest slept or ALVR
    /// closed), the headset closed its end, or the framing broke. The
    /// session owner must replace the whole ALVR session; `close()` does not
    /// call it.
    public var onTransportClosed: ((_ reason: String) -> Void)?
    public let transport: AlvrStreamTransport
    /// How long a USB (TCP) write may make no progress at all before the
    /// stream counts as dead. The adb USB link and the Quest's reader pause
    /// for up to ~1.5 s in both directions while ALVR keeps rendering; such a
    /// pause must only delay frames. Stale frames never queue meanwhile:
    /// `send` keeps at most one frame waiting and drops new frames once the
    /// write in flight is older than one frame period. Matches the control
    /// connection's silence timeout, so the video path never gives up first.
    public static let defaultTCPStallTimeoutNanoseconds =
        AlvrSessionHandshakeResult.defaultReceiveTimeoutNanoseconds
    private let tcpStallTimeoutNanoseconds: UInt64
    static let udpSendBufferBytes: Int32 = 64 * 1_024
    static let tcpSendBufferBytes: Int32 = 1 * 1_024 * 1_024
    static let tcpReceiveBufferBytes: Int32 = 1 * 1_024 * 1_024
    private let socket: Int32
    private let queue = DispatchQueue(label: "basalt.alvr.video")
    private let queueKey = DispatchSpecificKey<Void>()
    private var readSource: DispatchSourceRead?
    private var nextPacketIndex: UInt32 = 0
    private var nextHapticsPacketIndex: UInt32 = 0
    private var nextAudioPacketIndex: UInt32 = 0
    private let stateLock = NSLock()
    /// One frame period at 72 Hz, the Quest default, until the session
    /// negotiates its refresh rate (`setInFlightBusyThreshold`).
    public static let defaultInFlightBusyAfterNanoseconds: UInt64 =
        AlvrVideoSendAdmission.busyAfterNanoseconds(refreshRate: 72)!
    /// Guarded by `stateLock`.
    private var videoAdmission: AlvrVideoSendAdmission
    private var audioSendInFlight = false
    private var lastCongestionRecovery = DispatchTime(uptimeNanoseconds: 0)
    private var latestTrackingTimestamp: UInt64?
    private var latestTrackingArrival = DispatchTime(uptimeNanoseconds: 0)
    private var trackingArrivals = TrackingArrivalHistory()
    private var trackingReadyCallback: (() -> Void)?
    private var tcpReceiveBuffer = Data()
    /// Only touched on `queue`.
    private var trackingReassembler = AlvrTrackingReassembler()
    private var transportFailed = false
    private var uplinkStarted = false
    /// Only touched on `queue`, which also runs every write and read.
    private var socketClosed = false

    public init(host: String, remotePort: UInt16 = defaultPort,
                localPort: UInt16 = defaultPort,
                transport: AlvrStreamTransport = .udp,
                tcpStallTimeoutNanoseconds: UInt64 = defaultTCPStallTimeoutNanoseconds,
                inFlightBusyAfterNanoseconds: UInt64 = defaultInFlightBusyAfterNanoseconds) throws {
        self.transport = transport
        self.tcpStallTimeoutNanoseconds = tcpStallTimeoutNanoseconds
        self.videoAdmission = AlvrVideoSendAdmission(
            busyAfterNanoseconds: inFlightBusyAfterNanoseconds)
        let socketType = transport == .udp ? SOCK_DGRAM : SOCK_STREAM
        let fd = Darwin.socket(AF_INET, socketType, 0)
        guard fd >= 0 else { throw Self.socketError("video socket() failed") }
        do {
            if transport == .udp {
                var local = sockaddr_in()
                local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                local.sin_family = sa_family_t(AF_INET)
                local.sin_port = localPort.bigEndian
                local.sin_addr.s_addr = INADDR_ANY
                let bindResult = withUnsafePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bindResult == 0 else {
                    throw Self.socketError("Cannot bind ALVR video UDP port \(localPort)")
                }
            }

            var remote = sockaddr_in()
            remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            remote.sin_family = sa_family_t(AF_INET)
            remote.sin_port = remotePort.bigEndian
            guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else {
                throw BasaltError("Invalid ALVR video IPv4 address '\(host)'")
            }
            let oldFlags = fcntl(fd, F_GETFL)
            guard oldFlags >= 0,
                  fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK) == 0 else {
                throw Self.socketError("Cannot make ALVR video socket nonblocking")
            }
            let connectResult = withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connectResult != 0 && !(transport == .tcp && errno == EINPROGRESS) {
                throw Self.socketError("Cannot connect ALVR video \(transport.rawValue.uppercased()) socket to \(host):\(remotePort)")
            }
            if transport == .tcp, connectResult != 0 {
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&descriptor, 1, 5_000) > 0 else {
                    throw BasaltError("Timed out connecting ALVR USB stream at \(host):\(remotePort)")
                }
                var status: Int32 = 0
                var statusSize = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &status, &statusSize) == 0,
                      status == 0 else {
                    let message = String(cString: strerror(status == 0 ? errno : status))
                    throw BasaltError("Cannot connect ALVR USB stream at \(host):\(remotePort): \(message)")
                }
            }

            // Keep Wi-Fi UDP's queue small so congestion drops a fresh access
            // unit. Wired ALVR is different: upstream requests the maximum OS
            // TCP buffers, and a 64 KiB buffer makes ordinary IDRs repeatedly
            // block. One MiB matches the Quest client's observed receive window;
            // `send` keeps at most one access unit waiting behind the one in
            // flight, which bounds hidden delay while the headset is slow to
            // read.
            var sendBufferSize = transport == .tcp
                ? Self.tcpSendBufferBytes : Self.udpSendBufferBytes
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBufferSize,
                       socklen_t(MemoryLayout<Int32>.size))
            if transport == .tcp {
                var receiveBufferSize = Self.tcpReceiveBufferBytes
                setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBufferSize,
                           socklen_t(MemoryLayout<Int32>.size))
                var noDelay: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay,
                           socklen_t(MemoryLayout<Int32>.size))
                var noSigPipe: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                           socklen_t(MemoryLayout<Int32>.size))
            }
            socket = fd
            queue.setSpecific(key: queueKey, value: ())
            // Resumed by `start()`, once the owner has installed its handlers.
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drainUplink() }
            readSource = source
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeSocket()
        } else {
            queue.sync { closeSocket() }
        }
    }

    /// Starts reading the tracking/statistics uplink. Call once, after the
    /// `on…` handlers are set: uplink callbacks run on the sender's queue and
    /// must not race their own installation.
    public func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !uplinkStarted else { return }
        uplinkStarted = true
        readSource?.resume()
    }

    /// Closes the stream socket now, so a replacement session can bind the
    /// same UDP port. Idempotent; queued writes become no-ops and later
    /// sends report a drop. A write waiting on a paused USB stream notices
    /// within one poll interval. Does not call `onTransportClosed`.
    public func close() {
        stateLock.lock()
        transportFailed = true
        stateLock.unlock()
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeSocket()
        } else {
            queue.sync { closeSocket() }
        }
    }

    private func closeSocket() {
        guard !socketClosed else { return }
        socketClosed = true
        releaseReadSource()
        Darwin.close(socket)
    }

    /// Makes a write in flight count as busy after one frame period at
    /// `hertz`, the negotiated headset refresh rate. Returns false (and keeps
    /// the previous threshold) for a rate outside 30-240 Hz.
    @discardableResult
    public func setInFlightBusyThreshold(refreshRate hertz: Float) -> Bool {
        guard let threshold = AlvrVideoSendAdmission.busyAfterNanoseconds(
            refreshRate: hertz) else { return false }
        stateLock.lock()
        videoAdmission.busyAfterNanoseconds = threshold
        stateLock.unlock()
        return true
    }

    /// True when `send` would drop a frame handed to it now: the write in
    /// flight has run longer than one frame period (for example a paused
    /// USB link), a frame already waits behind it, or the transport failed.
    /// A write that started moments ago does not count: the next frame waits
    /// behind it. Callers skip *encoding* a frame while busy, which keeps
    /// the H.264 reference chain intact (see `VideoLossRecoveryGate`).
    public var isBusy: Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        defer { stateLock.unlock() }
        return transportFailed || videoAdmission.wouldDrop(now: now)
    }

    /// Cancels and drops the uplink read source. Releasing a suspended
    /// dispatch source crashes, so one that `start()` never resumed is
    /// resumed after the cancel. Runs on `queue`.
    private func releaseReadSource() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let source = readSource else { return }
        source.cancel()
        if !uplinkStarted {
            uplinkStarted = true
            source.resume()
        }
        readSource = nil
    }

    @discardableResult
    public func send(annexB: Data, timestampNanoseconds: UInt64, isIDR: Bool) -> Bool {
        stateLock.lock()
        guard !transportFailed,
              videoAdmission.admit(now: DispatchTime.now().uptimeNanoseconds) else {
            stateLock.unlock()
            onFrameDropped?()
            return false
        }
        stateLock.unlock()
        queue.async { [self] in
            defer {
                let now = DispatchTime.now().uptimeNanoseconds
                stateLock.lock()
                videoAdmission.complete(now: now)
                stateLock.unlock()
            }
            // A frame that waited behind a write that failed the transport.
            guard !socketClosed, !isTransportFailed else { return }
            do {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let shards = try AlvrVideoPacketizer.shards(
                    annexB: annexB, timestampNanoseconds: timestampNanoseconds,
                    isIDR: isIDR, packetIndex: nextPacketIndex)
                nextPacketIndex &+= 1
                var wireBytes = 0
                for shard in shards {
                    guard try sendShard(shard) else { return }
                    wireBytes += shard.count
                }
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                let duration = finishedAt &- startedAt
                stateLock.lock()
                let arrival = trackingArrivals.arrival(ofTimestamp: timestampNanoseconds)
                stateLock.unlock()
                onFrameSent?(AlvrVideoSendReport(
                    timestampNanoseconds: timestampNanoseconds,
                    accessUnitBytes: annexB.count,
                    wireBytes: wireBytes,
                    shardCount: shards.count,
                    isIDR: isIDR,
                    durationNanoseconds: duration,
                    trackingAgeNanoseconds: arrival.map {
                        finishedAt >= $0 ? finishedAt - $0 : 0
                    }))
            } catch {
                onError?(error)
                if transport == .tcp {
                    failTCPTransport(reason: error.localizedDescription)
                }
            }
        }
        return true
    }

    public func sendHaptics(hand: AlvrHand, durationNanoseconds: UInt64,
                            frequency: Float, amplitude: Float) {
        queue.async { [self] in
            do {
                stateLock.lock()
                let failed = transportFailed
                stateLock.unlock()
                guard !failed, !socketClosed else { return }
                let packet = try AlvrHapticsPacketizer.packet(
                    hand: hand, durationNanoseconds: durationNanoseconds,
                    frequency: frequency, amplitude: amplitude,
                    packetIndex: nextHapticsPacketIndex)
                nextHapticsPacketIndex &+= 1
                _ = try sendShard(packet, reportsVideoCongestion: false)
            } catch {
                onError?(error)
                if transport == .tcp { failTCPTransport(reason: error.localizedDescription) }
            }
        }
    }

    /// Audio callbacks can outpace a congested socket. Keep at most one audio
    /// block queued; dropping a self-contained PCM packet is preferable to
    /// accumulating audible latency.
    @discardableResult
    public func sendAudioPCM16(_ pcm16Stereo: Data) -> Bool {
        stateLock.lock()
        guard !audioSendInFlight, !transportFailed else {
            stateLock.unlock()
            onAudioDropped?()
            return false
        }
        audioSendInFlight = true
        stateLock.unlock()
        queue.async { [self] in
            defer {
                stateLock.lock()
                audioSendInFlight = false
                stateLock.unlock()
            }
            guard !socketClosed else { return }
            do {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let shards = try AlvrAudioPacketizer.shards(
                    pcm16Stereo: pcm16Stereo, packetIndex: nextAudioPacketIndex)
                nextAudioPacketIndex &+= 1
                var wireBytes = 0
                for shard in shards {
                    guard try sendShard(
                        shard, reportsVideoCongestion: false) else {
                        onAudioDropped?()
                        return
                    }
                    wireBytes += shard.count
                }
                onAudioSent?(AlvrAudioSendReport(
                    pcmBytes: pcm16Stereo.count, wireBytes: wireBytes,
                    shardCount: shards.count,
                    durationNanoseconds:
                        DispatchTime.now().uptimeNanoseconds &- startedAt))
            } catch {
                onError?(error)
                if transport == .tcp { failTCPTransport(reason: error.localizedDescription) }
            }
        }
        return true
    }

    /// Returns a recent Quest tracking timestamp so the video header uses the
    /// headset's OpenXR clock domain. Falling back to Mac uptime was enough to
    /// decode pictures but broke frame correlation, statistics, and pacing.
    public func timestampForVideoFrame() -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let age = DispatchTime.now().uptimeNanoseconds
            &- latestTrackingArrival.uptimeNanoseconds
        guard age < 100_000_000 else { return nil }
        return latestTrackingTimestamp
    }

    /// Installs the callback atomically and invokes it immediately if tracking
    /// won the race with stream setup. The first post-tracking video frame must
    /// be an IDR because earlier encoder output has intentionally been skipped.
    public func onTrackingReady(_ callback: @escaping () -> Void) {
        stateLock.lock()
        trackingReadyCallback = callback
        let isReady = latestTrackingTimestamp != nil
        stateLock.unlock()
        if isReady { callback() }
    }

    private func drainUplink() {
        guard !socketClosed else { return }
        var buffer = [UInt8](repeating: 0, count: transport == .tcp ? 64 * 1024 : 2_048)
        while true {
            let count = recv(socket, &buffer, buffer.count, 0)
            if count > 0 {
                if transport == .tcp {
                    tcpReceiveBuffer.append(contentsOf: buffer[0..<count])
                    guard drainTCPFrames() else { return }
                } else {
                    handleUplink(Data(buffer[0..<count]))
                }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if transport == .udp, count == 0 {
                continue  // an empty datagram
            } else if transport == .tcp {
                // EOF stays readable, so returning here would spin the read
                // source. The headset end is gone: ALVR closed or paused (the
                // Quest slept), or the cable was pulled.
                failTCPTransport(reason: count == 0
                    ? "the headset closed the USB stream"
                    : "USB stream read failed: \(String(cString: strerror(errno)))")
                return
            } else {
                // A connected UDP socket reports ICMP errors (for example
                // ECONNREFUSED while the client restarts) here. The control
                // connection decides when a Wi-Fi session is gone.
                return
            }
        }
    }

    /// Returns false once the stream framing is broken and the transport
    /// has been failed.
    private func drainTCPFrames() -> Bool {
        while tcpReceiveBuffer.count >= 4 {
            let prefix = tcpReceiveBuffer.prefix(4)
            let payloadLength = prefix.reduce(0) { ($0 << 8) | Int($1) }
            let packetLength = payloadLength + 4
            guard packetLength >= 18, packetLength <= 4 * 1_024 * 1_024 else {
                let error = BasaltError("Invalid ALVR TCP stream packet length \(packetLength)")
                tcpReceiveBuffer.removeAll()
                onError?(error)
                failTCPTransport(reason: error.localizedDescription)
                return false
            }
            guard tcpReceiveBuffer.count >= packetLength else { return true }
            let packet = Data(tcpReceiveBuffer.prefix(packetLength))
            tcpReceiveBuffer.removeFirst(packetLength)
            handleUplink(packet)
        }
        return true
    }

    private func handleUplink(_ data: Data) {
        // Tracking (stream 0) packets with hand skeletons span shards; join
        // them for the full sample. Shard 0 alone still feeds the head pose
        // below without waiting.
        let bytes = [UInt8](data)
        var sample: AlvrTrackingSample?
        if bytes.count >= 18, bytes[4] == 0, bytes[5] == 0,
           Int((0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[$1]) }) + 4 == bytes.count,
           let body = trackingReassembler.add(bytes) {
            sample = try? AlvrTrackingDecoder.decode(body)
        }
        handleUplinkHeader(data)
        if let sample { onTrackingSample?(sample) }
    }

    private func handleUplinkHeader(_ data: Data) {
        guard let packet = try? AlvrUplinkPacketDecoder.decode(data) else { return }
        switch packet {
        case .tracking(let timestamp, let headPose, _, _, _):
            stateLock.lock()
            let isFirstTrackingPacket = latestTrackingTimestamp == nil
            latestTrackingTimestamp = timestamp
            latestTrackingArrival = .now()
            trackingArrivals.record(
                timestampNanoseconds: timestamp,
                arrivalNanoseconds: latestTrackingArrival.uptimeNanoseconds)
            let callback = trackingReadyCallback
            stateLock.unlock()
            if isFirstTrackingPacket { callback?() }
            onTrackingTimestamp?(timestamp)
            if let headPose { onHeadPose?(timestamp, headPose) }
        case .statistics(let statistics):
            onStatistics?(statistics)
        case .other:
            break
        }
    }

    /// UDP packets are atomic and can be discarded before entering a hidden
    /// queue. TCP packets must be written completely because abandoning a
    /// partial length-framed shard would desynchronize the whole USB stream.
    /// While the headset is not reading, the wait keeps draining the uplink
    /// (this queue's other job), so tracking and statistics still reach the
    /// runtime. Returns false when the transport was closed or failed during
    /// the wait; throws only after `tcpStallTimeoutNanoseconds` with no
    /// progress, or on a socket error.
    private func sendShard(_ shard: Data,
                           reportsVideoCongestion: Bool = true) throws -> Bool {
        guard !socketClosed else { return false }
        if transport == .udp {
            let count = shard.withUnsafeBytes {
                Darwin.send(socket, $0.baseAddress, shard.count, 0)
            }
            if count < 0, errno == EAGAIN || errno == ENOBUFS {
                if reportsVideoCongestion { reportCongestion() }
                return false
            }
            guard count == shard.count else {
                throw Self.socketError("Failed sending ALVR video shard")
            }
            return true
        }

        var offset = 0
        var lastProgress = DispatchTime.now().uptimeNanoseconds
        while offset < shard.count {
            guard !socketClosed, !isTransportFailed else { return false }
            let count = shard.withUnsafeBytes {
                Darwin.send(socket, $0.baseAddress!.advanced(by: offset), shard.count - offset, 0)
            }
            if count > 0 {
                offset += count
                lastProgress = DispatchTime.now().uptimeNanoseconds
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                let stalled = DispatchTime.now().uptimeNanoseconds &- lastProgress
                guard stalled < tcpStallTimeoutNanoseconds else {
                    throw BasaltError(String(
                        format: "ALVR USB stream stalled: the headset read nothing for %.1f s",
                        Double(stalled) / 1e9))
                }
                let remaining = tcpStallTimeoutNanoseconds - stalled
                var descriptor = pollfd(
                    fd: socket, events: Int16(POLLOUT | POLLIN), revents: 0)
                let milliseconds = Int32(max(1, min(50, remaining / 1_000_000)))
                guard poll(&descriptor, 1, milliseconds) > 0 else { continue }
                if descriptor.revents & Int16(POLLIN) != 0 {
                    drainUplink()
                }
                continue
            }
            throw Self.socketError("Failed writing ALVR USB video stream")
        }
        return true
    }

    private var isTransportFailed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return transportFailed
    }

    /// TCP cannot recover after even one partially written shard: continuing
    /// would make the peer parse later bytes as the missing payload. Shutdown
    /// guarantees this connection is never reused. The owner is told once so
    /// it can replace the whole ALVR session instead of dropping every later
    /// frame as "network busy". Runs on `queue`.
    private func failTCPTransport(reason: String) {
        stateLock.lock()
        let wasFailed = transportFailed
        transportFailed = true
        stateLock.unlock()
        guard !wasFailed else { return }
        if !socketClosed {
            Darwin.shutdown(socket, SHUT_RDWR)
            releaseReadSource()
        }
        onTransportClosed?(reason)
    }

    private func reportCongestion() {
        onFrameDropped?()
        let now = DispatchTime.now()
        if now.uptimeNanoseconds &- lastCongestionRecovery.uptimeNanoseconds
            >= 500_000_000 {
            lastCongestionRecovery = now
            onCongestion?()
        }
    }

    private static func socketError(_ context: String) -> BasaltError {
        BasaltError("\(context): \(String(cString: strerror(errno)))")
    }
}

/// Thread-safe handoff between media callbacks and the stream that becomes
/// available after the Quest replies `StreamReady`.
public final class AlvrVideoStreamRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var sender: AlvrVideoStreamSender?
    private var controlSession: AlvrSessionHandshakeResult?
    /// The codec of every access unit passed to `send`; it selects the
    /// parameter-set NAL types and the `DecoderConfig` codec field.
    public let codec: VideoCodec

    public init(codec: VideoCodec = .h264) {
        self.codec = codec
    }

    public func install(_ sender: AlvrVideoStreamSender,
                        controlSession: AlvrSessionHandshakeResult) {
        lock.lock()
        self.sender = sender
        self.controlSession = controlSession
        lock.unlock()
    }

    /// Detaches `sender` if it is still the installed stream, so media
    /// callbacks stop reaching a dead ALVR session. Returns whether it was.
    @discardableResult
    public func uninstall(_ sender: AlvrVideoStreamSender) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.sender === sender else { return false }
        self.sender = nil
        controlSession = nil
        return true
    }

    /// True while an ALVR client session is installed. Without one, video
    /// work is wasted, so callers can drop frames before composing them.
    public var hasStream: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sender != nil
    }

    /// The newest fresh Quest tracking timestamp of the installed stream.
    public func timestampForVideoFrame() -> UInt64? {
        lock.lock()
        let sender = self.sender
        lock.unlock()
        return sender?.timestampForVideoFrame()
    }

    /// True when an installed stream would drop a frame submitted now: its
    /// write in flight is older than one frame period, the transport failed,
    /// or (desktop frames, which
    /// take the newest tracking timestamp) no fresh timestamp exists. False
    /// without a stream.
    public func isBusy(requiringTrackingTimestamp: Bool) -> Bool {
        lock.lock()
        let sender = self.sender
        lock.unlock()
        guard let sender else { return false }
        return sender.isBusy
            || (requiringTrackingTimestamp && sender.timestampForVideoFrame() == nil)
    }

    /// Runtime frames supply the exact Quest tracking timestamp used to
    /// locate that frame. Desktop frames omit it and retain the original
    /// behavior of sampling the newest tracking timestamp at send time.
    ///
    /// Returns false when a stream is installed but the frame did not reach
    /// it (no tracking timestamp, or the sender dropped it): the headset's
    /// reference chain is then broken. True when it was handed over, or when
    /// no stream is installed.
    @discardableResult
    public func send(annexB: Data, isIDR: Bool,
                     timestampNanoseconds suppliedTimestamp: UInt64? = nil) -> Bool {
        lock.lock()
        let sender = self.sender
        let controlSession = self.controlSession
        lock.unlock()
        if isIDR, let parameterSets = VideoParameterSets.extract(from: annexB, codec: codec) {
            controlSession?.sendDecoderConfig(parameterSets, codec: codec)
        }
        guard let sender else { return true }
        guard let timestamp = suppliedTimestamp ?? sender.timestampForVideoFrame() else {
            return false
        }
        return sender.send(annexB: annexB, timestampNanoseconds: timestamp, isIDR: isIDR)
    }

    @discardableResult
    public func sendAudioPCM16(_ pcm16Stereo: Data) -> Bool {
        lock.lock()
        let sender = self.sender
        lock.unlock()
        return sender?.sendAudioPCM16(pcm16Stereo) ?? false
    }
}

public enum H264ParameterSets {
    /// Extracts SPS (type 7) and PPS (type 8) NAL units, preserving Annex-B
    /// start codes for ALVR's MediaCodec initialization buffer.
    public static func extract(from annexB: Data) -> Data? {
        VideoParameterSets.extract(from: annexB, codec: .h264)
    }
}

public enum VideoParameterSets {
    /// Extracts the parameter-set NAL units of an IDR access unit — SPS and
    /// PPS (H.264 types 7, 8) or VPS, SPS, and PPS (HEVC types 32, 33, 34) —
    /// with 4-byte Annex-B start codes, in stream order. This is ALVR's
    /// `DecoderConfig` buffer: the Quest passes it to MediaCodec as `csd-0`
    /// (`client_core/src/video_decoder/android.rs`), and the stock server
    /// sends the same leading VPS+SPS+PPS (H.264: SPS+PPS) NAL units
    /// (`server_openvr/cpp/alvr_server/NalParsing.cpp`).
    public static func extract(from annexB: Data, codec: VideoCodec) -> Data? {
        let bytes = [UInt8](annexB)
        var starts = [(offset: Int, codeLength: Int)]()
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index...index + 3].elementsEqual([0, 0, 0, 1]) {
                starts.append((index, 4))
                index += 4
            } else if bytes[index...index + 2].elementsEqual([0, 0, 1]) {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }

        var result = Data()
        for (position, start) in starts.enumerated() {
            let naluStart = start.offset + start.codeLength
            let naluEnd = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            guard naluStart < naluEnd else { continue }
            let type = codec.nalUnitType(headerByte: bytes[naluStart])
            guard codec.parameterSetNALTypes.contains(type) else { continue }
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(contentsOf: bytes[naluStart..<naluEnd])
        }
        return result.isEmpty ? nil : result
    }
}
