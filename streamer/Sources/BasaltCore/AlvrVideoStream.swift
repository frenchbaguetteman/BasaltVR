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

    public init(timestampNanoseconds: UInt64, accessUnitBytes: Int,
                wireBytes: Int, shardCount: Int, isIDR: Bool,
                durationNanoseconds: UInt64) {
        self.timestampNanoseconds = timestampNanoseconds
        self.accessUnitBytes = accessUnitBytes
        self.wireBytes = wireBytes
        self.shardCount = shardCount
        self.isIDR = isIDR
        self.durationNanoseconds = durationNanoseconds
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
    public var onControllerMotion: ((_ timestampNanoseconds: UInt64, _ hand: AlvrHand,
                                     _ motion: AlvrControllerMotion) -> Void)?
    public var onControllerMask: ((_ timestampNanoseconds: UInt64, _ activeMask: UInt32) -> Void)?
    public var onFrameSent: ((AlvrVideoSendReport) -> Void)?
    public var onAudioSent: ((AlvrAudioSendReport) -> Void)?
    public var onAudioDropped: (() -> Void)?
    public let transport: AlvrStreamTransport
    /// The upper bound is deliberately several frame intervals: an IDR can be
    /// much larger than a P-frame, but stale frames must not queue indefinitely.
    static let tcpAccessUnitDeadlineNanoseconds: UInt64 = 50_000_000
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
    private var sendInFlight = false
    private var audioSendInFlight = false
    private var lastCongestionRecovery = DispatchTime(uptimeNanoseconds: 0)
    private var latestTrackingTimestamp: UInt64?
    private var latestTrackingArrival = DispatchTime(uptimeNanoseconds: 0)
    private var trackingReadyCallback: (() -> Void)?
    private var tcpReceiveBuffer = Data()
    private var transportFailed = false
    private var uplinkStarted = false

    public init(host: String, remotePort: UInt16 = defaultPort,
                localPort: UInt16 = defaultPort,
                transport: AlvrStreamTransport = .udp) throws {
        self.transport = transport
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
            // the whole-access-unit deadline below still bounds hidden delay.
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
            close(fd)
            throw error
        }
    }

    deinit {
        readSource?.cancel()
        // Releasing a suspended dispatch source crashes.
        if !uplinkStarted { readSource?.resume() }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            close(socket)
        } else {
            _ = queue.sync { close(socket) }
        }
    }

    /// Starts reading the tracking/statistics uplink. Call once, after the
    /// `on…` handlers are set: uplink callbacks run on the sender's queue and
    /// must not race their own installation.
    public func start() {
        stateLock.lock()
        let alreadyStarted = uplinkStarted
        uplinkStarted = true
        stateLock.unlock()
        guard !alreadyStarted else { return }
        readSource?.resume()
    }

    @discardableResult
    public func send(annexB: Data, timestampNanoseconds: UInt64, isIDR: Bool) -> Bool {
        stateLock.lock()
        guard !sendInFlight, !transportFailed else {
            stateLock.unlock()
            onFrameDropped?()
            return false
        }
        sendInFlight = true
        stateLock.unlock()
        queue.async { [self] in
            defer {
                stateLock.lock()
                sendInFlight = false
                stateLock.unlock()
            }
            do {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let deadline = startedAt &+ Self.tcpAccessUnitDeadlineNanoseconds
                let shards = try AlvrVideoPacketizer.shards(
                    annexB: annexB, timestampNanoseconds: timestampNanoseconds,
                    isIDR: isIDR, packetIndex: nextPacketIndex)
                nextPacketIndex &+= 1
                var wireBytes = 0
                for shard in shards {
                    guard try sendShard(shard, deadline: deadline) else { return }
                    wireBytes += shard.count
                }
                let duration = DispatchTime.now().uptimeNanoseconds &- startedAt
                onFrameSent?(AlvrVideoSendReport(
                    timestampNanoseconds: timestampNanoseconds,
                    accessUnitBytes: annexB.count,
                    wireBytes: wireBytes,
                    shardCount: shards.count,
                    isIDR: isIDR,
                    durationNanoseconds: duration))
            } catch {
                if transport == .tcp {
                    failTCPTransport()
                }
                onError?(error)
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
                guard !failed else { return }
                let packet = try AlvrHapticsPacketizer.packet(
                    hand: hand, durationNanoseconds: durationNanoseconds,
                    frequency: frequency, amplitude: amplitude,
                    packetIndex: nextHapticsPacketIndex)
                nextHapticsPacketIndex &+= 1
                let deadline = DispatchTime.now().uptimeNanoseconds
                    &+ Self.tcpAccessUnitDeadlineNanoseconds
                _ = try sendShard(packet, deadline: deadline, reportsVideoCongestion: false)
            } catch {
                if transport == .tcp { failTCPTransport() }
                onError?(error)
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
            do {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let deadline = startedAt
                    &+ Self.tcpAccessUnitDeadlineNanoseconds
                let shards = try AlvrAudioPacketizer.shards(
                    pcm16Stereo: pcm16Stereo, packetIndex: nextAudioPacketIndex)
                nextAudioPacketIndex &+= 1
                var wireBytes = 0
                for shard in shards {
                    guard try sendShard(
                        shard, deadline: deadline,
                        reportsVideoCongestion: false) else {
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
                if transport == .tcp { failTCPTransport() }
                onError?(error)
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
        var buffer = [UInt8](repeating: 0, count: transport == .tcp ? 64 * 1024 : 2_048)
        while true {
            let count = recv(socket, &buffer, buffer.count, 0)
            if count > 0 {
                if transport == .tcp {
                    tcpReceiveBuffer.append(contentsOf: buffer[0..<count])
                    drainTCPFrames()
                } else {
                    handleUplink(Data(buffer[0..<count]))
                }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if transport == .udp, count == 0 {
                continue  // an empty datagram
            } else if transport == .udp, errno == ECONNREFUSED {
                // A briefly unreachable headset; recv consumed the ICMP error.
                return
            } else {
                // EOF or a hard error leaves the descriptor readable forever;
                // returning would spin the read source at full CPU.
                let error = count == 0
                    ? BasaltError("ALVR USB stream closed by the headset")
                    : Self.socketError("ALVR stream uplink failed")
                if transport == .tcp {
                    failTCPTransport()
                } else {
                    readSource?.cancel()
                }
                onError?(error)
                return
            }
        }
    }

    private func drainTCPFrames() {
        while tcpReceiveBuffer.count >= 4 {
            let prefix = tcpReceiveBuffer.prefix(4)
            let payloadLength = prefix.reduce(0) { ($0 << 8) | Int($1) }
            let packetLength = payloadLength + 4
            guard packetLength >= 18, packetLength <= 4 * 1_024 * 1_024 else {
                stateLock.lock()
                transportFailed = true
                stateLock.unlock()
                onError?(BasaltError("Invalid ALVR TCP stream packet length \(packetLength)"))
                readSource?.cancel()
                return
            }
            guard tcpReceiveBuffer.count >= packetLength else { return }
            let packet = Data(tcpReceiveBuffer.prefix(packetLength))
            tcpReceiveBuffer.removeFirst(packetLength)
            handleUplink(packet)
        }
    }

    private func handleUplink(_ data: Data) {
        guard let packet = try? AlvrUplinkPacketDecoder.decode(data) else { return }
        switch packet {
        case .tracking(let timestamp, let headPose, let leftController,
                       let rightController, let controllerMask):
            stateLock.lock()
            let isFirstTrackingPacket = latestTrackingTimestamp == nil
            latestTrackingTimestamp = timestamp
            latestTrackingArrival = .now()
            let callback = trackingReadyCallback
            stateLock.unlock()
            if isFirstTrackingPacket { callback?() }
            if let headPose { onHeadPose?(timestamp, headPose) }
            if let leftController { onControllerMotion?(timestamp, .left, leftController) }
            if let rightController { onControllerMotion?(timestamp, .right, rightController) }
            onControllerMask?(timestamp, controllerMask)
        case .statistics(let statistics):
            onStatistics?(statistics)
        case .other:
            break
        }
    }

    /// UDP packets are atomic and can be discarded before entering a hidden
    /// queue. TCP packets must be written completely because abandoning a
    /// partial length-framed shard would desynchronize the whole USB stream.
    private func sendShard(_ shard: Data, deadline: UInt64,
                           reportsVideoCongestion: Bool = true) throws -> Bool {
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
        while offset < shard.count {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw BasaltError("Timed out writing one ALVR USB video access unit")
            }
            let count = shard.withUnsafeBytes {
                Darwin.send(socket, $0.baseAddress!.advanced(by: offset), shard.count - offset, 0)
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                let remaining = deadline > DispatchTime.now().uptimeNanoseconds
                    ? deadline - DispatchTime.now().uptimeNanoseconds : 0
                guard remaining > 0 else {
                    throw BasaltError("Timed out writing one ALVR USB video access unit")
                }
                var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
                let milliseconds = Int32(max(1, min(50, remaining / 1_000_000)))
                guard poll(&descriptor, 1, milliseconds) > 0 else { continue }
                continue
            }
            throw Self.socketError("Failed writing ALVR USB video stream")
        }
        return true
    }

    /// TCP cannot recover after even one partially written shard: continuing
    /// would make the peer parse later bytes as the missing payload. Shutdown
    /// wakes the read source and guarantees this connection is never reused.
    private func failTCPTransport() {
        stateLock.lock()
        let wasFailed = transportFailed
        transportFailed = true
        stateLock.unlock()
        guard !wasFailed else { return }
        Darwin.shutdown(socket, SHUT_RDWR)
        readSource?.cancel()
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

    public init() {}

    public func install(_ sender: AlvrVideoStreamSender,
                        controlSession: AlvrSessionHandshakeResult) {
        lock.lock()
        self.sender = sender
        self.controlSession = controlSession
        lock.unlock()
    }

    /// Runtime frames supply the exact Quest tracking timestamp used to
    /// locate that frame. Desktop frames omit it and retain the original
    /// behavior of sampling the newest tracking timestamp at send time.
    public func send(annexB: Data, isIDR: Bool,
                     timestampNanoseconds suppliedTimestamp: UInt64? = nil) {
        lock.lock()
        let sender = self.sender
        let controlSession = self.controlSession
        lock.unlock()
        if isIDR, let parameterSets = H264ParameterSets.extract(from: annexB) {
            controlSession?.sendH264DecoderConfig(parameterSets)
        }
        guard let sender,
              let timestamp = suppliedTimestamp ?? sender.timestampForVideoFrame() else { return }
        sender.send(annexB: annexB, timestampNanoseconds: timestamp, isIDR: isIDR)
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
            let type = bytes[naluStart] & 0x1F
            guard type == 7 || type == 8 else { continue }
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(contentsOf: bytes[naluStart..<naluEnd])
        }
        return result.isEmpty ? nil : result
    }
}
