import Foundation

/// The first packet sent by an ALVR v20 client after the streamer connects
/// to its TCP control port.
public enum AlvrClientConnectionState: Equatable, Sendable {
    case accepted(protocolId: UInt64, displayName: String, serverIP: String,
                  capabilities: AlvrVideoCapabilities?)
    case standby
}

public struct AlvrVideoCapabilities: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let refreshRates: [Float]
    public let microphoneSampleRate: UInt32
    public let supportsFoveatedEncoding: Bool
    public let supportsHighProfile: Bool
    public let supports10Bit: Bool
    public let supportsAV1: Bool
    public let prefers10Bit: Bool
    public let prefersFullRange: Bool
    public let preferredEncodingGamma: Float
    public let prefersHDR: Bool
}

public struct AlvrFov: Equatable, Sendable {
    public let left: Float
    public let right: Float
    public let up: Float
    public let down: Float
}

public struct AlvrViewsConfig: Equatable, Sendable {
    public let ipdMeters: Float
    public let fov: [AlvrFov]
}

public enum AlvrButtonValue: Equatable, Sendable {
    case binary(Bool)
    case scalar(Float)
}

public struct AlvrButtonEntry: Equatable, Sendable {
    public let pathID: UInt64
    public let value: AlvrButtonValue

    public init(pathID: UInt64, value: AlvrButtonValue) {
        self.pathID = pathID
        self.value = value
    }
}

public enum AlvrClientControlEvent: Equatable, Sendable {
    case requestIDR
    case viewsConfig(AlvrViewsConfig)
    case buttons([AlvrButtonEntry])
    case activeInteractionProfile(deviceID: UInt64, profileID: UInt64)
    case keepAlive
    case other(variant: UInt32)
}

/// Decodes the client-to-server packets Basalt needs while streaming. ALVR
/// uses little-endian bincode enum discriminants and raw IEEE-754 floats.
public enum AlvrClientControlDecoder {
    public static func decode(_ payload: Data) throws -> AlvrClientControlEvent {
        var reader = LittleEndianReader(payload)
        let variant = try reader.readUInt32()
        switch variant {
        case 1:
            return .requestIDR
        case 2:
            return .keepAlive
        case 4:
            let ipd = try reader.readFloat32()
            var fov = [AlvrFov]()
            for _ in 0..<2 {
                fov.append(AlvrFov(left: try reader.readFloat32(),
                                   right: try reader.readFloat32(),
                                   up: try reader.readFloat32(),
                                   down: try reader.readFloat32()))
            }
            guard reader.isAtEnd, ipd.isFinite, ipd > 0,
                  fov.allSatisfy({ $0.left.isFinite && $0.right.isFinite
                      && $0.up.isFinite && $0.down.isFinite }) else {
                throw BasaltError("Invalid ALVR views configuration")
            }
            return .viewsConfig(AlvrViewsConfig(ipdMeters: ipd, fov: fov))
        case 7:
            let count = try reader.readUInt64()
            guard count <= 256 else { throw BasaltError("ALVR button update is too large") }
            var entries = [AlvrButtonEntry]()
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                let pathID = try reader.readUInt64()
                let value: AlvrButtonValue
                switch try reader.readUInt32() {
                case 0:
                    let raw = try reader.readByte()
                    guard raw <= 1 else { throw BasaltError("Invalid ALVR binary button") }
                    value = .binary(raw == 1)
                case 1:
                    let scalar = try reader.readFloat32()
                    guard scalar.isFinite else { throw BasaltError("Invalid ALVR scalar button") }
                    value = .scalar(scalar)
                default:
                    throw BasaltError("Unknown ALVR button value type")
                }
                entries.append(AlvrButtonEntry(pathID: pathID, value: value))
            }
            guard reader.isAtEnd else { throw BasaltError("Trailing ALVR button data") }
            return .buttons(entries)
        case 8:
            let deviceID = try reader.readUInt64()
            let profileID = try reader.readUInt64()
            guard reader.isAtEnd else { throw BasaltError("Trailing ALVR profile data") }
            return .activeInteractionProfile(deviceID: deviceID, profileID: profileID)
        default:
            return .other(variant: variant)
        }
    }
}

public final class AlvrSessionHandshakeResult: @unchecked Sendable {
    static let maximumRetainedButtonPaths = 64
    /// ALVR v20 clients send `KeepAlive` every 500 ms while streaming and
    /// drop the server after 2 s without one. Silence this long means the
    /// client is gone even if TCP never reported it (Wi-Fi out of range).
    public static let defaultReceiveTimeoutNanoseconds: UInt64 = 5_000_000_000
    public let clientState: AlvrClientConnectionState
    public let negotiatedSettings: AlvrNegotiatedSettings?
    public let streamReady: Bool
    private let socket: Int32
    private let receiveTimeoutNanoseconds: UInt64
    private var lastReceiveNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var keepaliveTimer: DispatchSourceTimer?
    private let controlQueue: DispatchQueue
    private let controlQueueKey = DispatchSpecificKey<Void>()
    private var readSource: DispatchSourceRead?
    private var receiveBuffer = Data()
    private var requestIDRHandler: (() -> Void)?
    private var viewsConfigHandler: ((AlvrViewsConfig) -> Void)?
    private var buttonsHandler: (([AlvrButtonEntry]) -> Void)?
    private var interactionProfileHandler: ((_ deviceID: UInt64, _ profileID: UInt64) -> Void)?
    private var disconnectHandler: ((_ reason: String) -> Void)?
    private var disconnectReason: String?
    private var disconnected: Bool { disconnectReason != nil }
    private var pendingIDRRequest = false
    private var latestViewsConfig: AlvrViewsConfig?
    private var latestButtons: [UInt64: AlvrButtonValue] = [:]
    private var latestInteractionProfiles: [UInt64: UInt64] = [:]

    init(clientState: AlvrClientConnectionState,
         negotiatedSettings: AlvrNegotiatedSettings?,
         streamReady: Bool, socket: Int32,
         receiveTimeoutNanoseconds: UInt64 = defaultReceiveTimeoutNanoseconds) {
        self.clientState = clientState
        self.negotiatedSettings = negotiatedSettings
        self.streamReady = streamReady
        self.socket = socket
        self.receiveTimeoutNanoseconds = receiveTimeoutNanoseconds
        let socketFlags = fcntl(socket, F_GETFL)
        if socketFlags >= 0 {
            _ = fcntl(socket, F_SETFL, socketFlags | O_NONBLOCK)
        }
        let queue = DispatchQueue(label: "basalt.alvr.control.live")
        controlQueue = queue
        queue.setSpecific(key: controlQueueKey, value: ())
        if streamReady {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(500),
                           repeating: .milliseconds(500))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let silence = DispatchTime.now().uptimeNanoseconds &- lastReceiveNanoseconds
                if silence >= receiveTimeoutNanoseconds {
                    handleDisconnect(reason: String(
                        format: "no ALVR control packets for %.1f s", Double(silence) / 1e9))
                    return
                }
                do {
                    try AlvrControlProbe.sendKeepAlive(to: socket)
                } catch {
                    self.handleDisconnect(
                        reason: "keepalive failed: \(error.localizedDescription)")
                }
            }
            timer.resume()
            keepaliveTimer = timer

            let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler { [weak self] in self?.drainControlSocket() }
            source.resume()
            readSource = source
        } else {
            keepaliveTimer = nil
        }
    }

    deinit {
        keepaliveTimer?.cancel()
        readSource?.cancel()
        if DispatchQueue.getSpecific(key: controlQueueKey) != nil {
            Darwin.close(socket)
        } else {
            _ = controlQueue.sync { Darwin.close(socket) }
        }
    }

    public func onRequestIDR(_ handler: @escaping () -> Void) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            requestIDRHandler = handler
            if pendingIDRRequest {
                pendingIDRRequest = false
                handler()
            }
        }
    }

    public func onViewsConfig(_ handler: @escaping (AlvrViewsConfig) -> Void) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            viewsConfigHandler = handler
            if let latestViewsConfig { handler(latestViewsConfig) }
        }
    }

    public func onButtons(_ handler: @escaping ([AlvrButtonEntry]) -> Void) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            buttonsHandler = handler
            if !latestButtons.isEmpty {
                handler(latestButtons.map { AlvrButtonEntry(pathID: $0.key, value: $0.value) })
            }
        }
    }

    public func onActiveInteractionProfile(
        _ handler: @escaping (_ deviceID: UInt64, _ profileID: UInt64) -> Void
    ) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            interactionProfileHandler = handler
            for (deviceID, profileID) in latestInteractionProfiles {
                handler(deviceID, profileID)
            }
        }
    }

    /// Called once when the live ALVR control socket reaches EOF, fails, or
    /// stays silent past the receive timeout. Installing the handler after
    /// the failure still reports it immediately. `close()` does not call it.
    public func onDisconnect(_ handler: @escaping (_ reason: String) -> Void) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            disconnectHandler = handler
            if let disconnectReason { handler(disconnectReason) }
        }
    }

    /// Ends this control session from the streamer side. The client sees EOF
    /// and returns to its connection loop, ready for a new handshake.
    public func close() {
        let work = { [self] in
            guard !disconnected else { return }
            let handler = disconnectHandler
            disconnectHandler = nil
            handleDisconnect(reason: "closed by Basalt")
            disconnectHandler = handler
        }
        if DispatchQueue.getSpecific(key: controlQueueKey) != nil {
            work()
        } else {
            controlQueue.sync(execute: work)
        }
    }

    static func retainButtonEntries(
        _ entries: [AlvrButtonEntry],
        in values: inout [UInt64: AlvrButtonValue],
        capacity: Int = maximumRetainedButtonPaths
    ) -> [AlvrButtonEntry] {
        var retained = [AlvrButtonEntry]()
        retained.reserveCapacity(min(entries.count, capacity))
        for entry in entries {
            guard values[entry.pathID] != nil || values.count < capacity else { continue }
            values[entry.pathID] = entry.value
            retained.append(entry)
        }
        return retained
    }

    public func sendH264DecoderConfig(_ parameterSets: Data) {
        sendDecoderConfig(parameterSets, codec: .h264)
    }

    /// Sends ALVR's `DecoderConfig`: the codec and the Annex-B parameter sets
    /// that the Quest uses to (re)create its decoder.
    public func sendDecoderConfig(_ parameterSets: Data, codec: VideoCodec) {
        guard streamReady, !parameterSets.isEmpty else { return }
        controlQueue.sync { [self] in
            guard !disconnected else { return }
            try? AlvrControlProbe.sendDecoderConfig(parameterSets, codec: codec, to: socket)
        }
    }

    private func drainControlSocket() {
        guard !disconnected else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = recv(socket, &bytes, bytes.count, 0)
            if count > 0 {
                receiveBuffer.append(contentsOf: bytes[0..<count])
                lastReceiveNanoseconds = DispatchTime.now().uptimeNanoseconds
            } else if count == 0 {
                handleDisconnect(reason: "the headset closed the ALVR control connection")
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else if errno == EINTR {
                continue
            } else {
                handleDisconnect(reason: "ALVR control read failed: "
                    + String(cString: strerror(errno)))
                return
            }
        }

        while receiveBuffer.count >= 4 {
            let length = receiveBuffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= AlvrControlProbe.maximumPacketBytes else {
                receiveBuffer.removeAll()
                handleDisconnect(reason: "invalid ALVR control packet length \(length)")
                return
            }
            guard receiveBuffer.count >= 4 + length else { return }
            let payloadStart = receiveBuffer.index(receiveBuffer.startIndex, offsetBy: 4)
            let payloadEnd = receiveBuffer.index(payloadStart, offsetBy: length)
            let payload = Data(receiveBuffer[payloadStart..<payloadEnd])
            receiveBuffer.removeFirst(4 + length)
            guard let event = try? AlvrClientControlDecoder.decode(payload) else { continue }
            switch event {
            case .requestIDR:
                if let requestIDRHandler {
                    requestIDRHandler()
                } else {
                    pendingIDRRequest = true
                }
            case .viewsConfig(let config):
                latestViewsConfig = config
                viewsConfigHandler?(config)
            case .buttons(let entries):
                let retained = Self.retainButtonEntries(entries, in: &latestButtons)
                if !retained.isEmpty { buttonsHandler?(retained) }
            case .activeInteractionProfile(let deviceID, let profileID):
                latestInteractionProfiles[deviceID] = profileID
                interactionProfileHandler?(deviceID, profileID)
            case .keepAlive, .other:
                break
            }
        }
    }

    private func handleDisconnect(reason: String) {
        guard !disconnected else { return }
        disconnectReason = reason
        keepaliveTimer?.cancel()
        readSource?.cancel()
        Darwin.shutdown(socket, SHUT_RDWR)
        receiveBuffer.removeAll()
        pendingIDRRequest = false
        latestViewsConfig = nil
        latestButtons.removeAll()
        latestInteractionProfiles.removeAll()
        disconnectHandler?(reason)
    }
}

/// Minimal decoder for the stable prefix of ALVR v20's bincode-encoded
/// `ClientConnectionResult`. The accepted packet has more capability fields,
/// but they are deliberately left for session negotiation.
public enum AlvrClientConnectionDecoder {
    public static func decode(_ payload: Data) throws -> AlvrClientConnectionState {
        var reader = LittleEndianReader(payload)
        let variant = try reader.readUInt32()
        switch variant {
        case 0:
            let protocolId = try reader.readUInt64()
            let displayName = try reader.readString(maxBytes: 4_096)
            let serverIP = try reader.readIPAddress()
            let hasCapabilities = try reader.readByte()
            let capabilities: AlvrVideoCapabilities?
            switch hasCapabilities {
            case 0:
                capabilities = nil
            case 1:
                capabilities = try reader.readVideoCapabilities()
            default:
                throw BasaltError("Invalid ALVR capabilities option tag \(hasCapabilities)")
            }
            guard reader.isAtEnd else { throw BasaltError("Unexpected trailing ALVR control data") }
            return .accepted(protocolId: protocolId, displayName: displayName,
                             serverIP: serverIP, capabilities: capabilities)
        case 1:
            return .standby
        default:
            throw BasaltError("Unknown ALVR client connection variant \(variant)")
        }
    }
}

/// Connects to the headset's ALVR TCP control port and reads its initial
/// length-prefixed client status packet. Socket work runs off the cooperative
/// Swift executor because the BSD operations are intentionally synchronous.
public enum AlvrControlProbe {
    public static let maximumPacketBytes = 1024 * 1024

    public static func connect(host: String,
                               port: UInt16 = AlvrDiscoveryListener.alvrPort,
                               timeoutSeconds: Int = 2) async throws -> AlvrClientConnectionState {
        try await Task.detached(priority: .utility) {
            try connectBlocking(host: host, port: port, timeoutSeconds: timeoutSeconds)
        }.value
    }

    /// Performs the complete TCP control handshake up to the point where the
    /// headset has opened its stream socket and replied with `StreamReady`.
    public static func negotiateSession(
        host: String,
        port: UInt16 = AlvrDiscoveryListener.alvrPort,
        timeoutSeconds: Int = 5,
        requestedViewWidth: UInt32? = nil,
        requestedViewHeight: UInt32? = nil,
        preferredRefreshRate: Float = 90,
        latencyPreset: StreamLatencyPreset = .balanced,
        wired: Bool = false,
        controllerPrediction: ControllerPrediction = .full,
        codec: VideoCodec = .h264
    ) async throws -> AlvrSessionHandshakeResult {
        try await Task.detached(priority: .utility) {
            try negotiateBlocking(host: host, port: port, timeoutSeconds: timeoutSeconds,
                                  requestedViewWidth: requestedViewWidth,
                                  requestedViewHeight: requestedViewHeight,
                                  preferredRefreshRate: preferredRefreshRate,
                                  latencyPreset: latencyPreset,
                                  wired: wired,
                                  controllerPrediction: controllerPrediction,
                                  codec: codec)
        }.value
    }

    private static func connectBlocking(host: String, port: UInt16,
                                        timeoutSeconds: Int) throws -> AlvrClientConnectionState {
        let fd = try openSocket(host: host, port: port, timeoutSeconds: timeoutSeconds)
        defer { close(fd) }
        return try receiveClientState(from: fd, timeoutSeconds: timeoutSeconds)
    }

    private static func negotiateBlocking(host: String, port: UInt16,
                                          timeoutSeconds: Int,
                                          requestedViewWidth: UInt32?,
                                          requestedViewHeight: UInt32?,
                                          preferredRefreshRate: Float,
                                          latencyPreset: StreamLatencyPreset,
                                          wired: Bool,
                                          controllerPrediction: ControllerPrediction,
                                          codec: VideoCodec) throws
        -> AlvrSessionHandshakeResult {
        let fd = try openSocket(host: host, port: port, timeoutSeconds: timeoutSeconds)
        do {
            let clientState: AlvrClientConnectionState
            do {
                clientState = try receiveClientState(from: fd, timeoutSeconds: timeoutSeconds)
            } catch {
                throw BasaltError("ALVR initial client-status stage failed: \(error.localizedDescription)")
            }
            guard case .accepted(_, _, _, let capabilities?) = clientState else {
                return AlvrSessionHandshakeResult(clientState: clientState,
                                                  negotiatedSettings: nil, streamReady: false,
                                                  socket: fd)
            }

            let settings: AlvrNegotiatedSettings
            if let requestedViewWidth, let requestedViewHeight {
                settings = try AlvrNegotiatedSettings.desktopPreviewDefaults(
                    for: capabilities, requestedWidth: requestedViewWidth,
                    requestedHeight: requestedViewHeight,
                    preferredRefreshRate: preferredRefreshRate,
                    latencyPreset: latencyPreset)
            } else {
                settings = try AlvrNegotiatedSettings.beatSaberDefaults(for: capabilities)
            }
            let streamConfig = try AlvrStreamConfigEncoder.framedPacket(
                settings: settings, wired: wired, controllerPrediction: controllerPrediction,
                codec: codec)
            do {
                try writeExactly(streamConfig, to: fd,
                                 deadline: Date().addingTimeInterval(TimeInterval(timeoutSeconds)))

                // ServerControlPacket::StartStream is enum variant 0 in ALVR v20.
                try writeExactly(framedPayload(Data([0, 0, 0, 0])), to: fd,
                                 deadline: Date().addingTimeInterval(TimeInterval(timeoutSeconds)))
            } catch {
                throw BasaltError("ALVR session-configuration stage failed: \(error.localizedDescription)")
            }

            let response: Data
            do {
                response = try readFramedPayload(from: fd, timeoutSeconds: timeoutSeconds)
            } catch {
                throw BasaltError("ALVR waiting-for-StreamReady stage failed: \(error.localizedDescription)")
            }
            guard response == Data([3, 0, 0, 0]) else {
                throw BasaltError("Expected ALVR StreamReady, received control payload \(response.hexPrefix)")
            }
            return AlvrSessionHandshakeResult(clientState: clientState,
                                              negotiatedSettings: settings, streamReady: true,
                                              socket: fd)
        } catch {
            close(fd)
            throw error
        }
    }

    private static func openSocket(host: String, port: UInt16,
                                   timeoutSeconds: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("control socket() failed") }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                throw BasaltError("Invalid ALVR client IPv4 address '\(host)'")
            }

            let oldFlags = fcntl(fd, F_GETFL)
            guard oldFlags >= 0, fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK) == 0 else {
                throw socketError("control fcntl() failed")
            }
            let connectResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connectResult != 0 && errno != EINPROGRESS {
                throw socketError("Cannot connect to ALVR client \(host):\(port)")
            }

            let timeoutMs = Int32(max(1, timeoutSeconds) * 1_000)
            if connectResult != 0 {
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&descriptor, 1, timeoutMs) > 0 else {
                    throw BasaltError("Timed out connecting to ALVR client \(host):\(port)")
                }
                var socketStatus: Int32 = 0
                var statusSize = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketStatus, &statusSize) == 0,
                      socketStatus == 0 else {
                    let message = socketStatus == 0 ? String(cString: strerror(errno))
                                                    : String(cString: strerror(socketStatus))
                    throw BasaltError("Cannot connect to ALVR client \(host):\(port): \(message)")
                }
            }

            var noDelay: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay,
                       socklen_t(MemoryLayout<Int32>.size))
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                       socklen_t(MemoryLayout<Int32>.size))
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func receiveClientState(from fd: Int32,
                                           timeoutSeconds: Int) throws -> AlvrClientConnectionState {
        let payload = try readFramedPayload(from: fd, timeoutSeconds: timeoutSeconds)
        return try AlvrClientConnectionDecoder.decode(payload)
    }

    private static func readFramedPayload(from fd: Int32, timeoutSeconds: Int) throws -> Data {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let prefix = try readExactly(4, from: fd, deadline: deadline)
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= maximumPacketBytes else {
            throw BasaltError("Invalid ALVR control packet length \(length)")
        }
        return try readExactly(length, from: fd, deadline: deadline)
    }

    fileprivate static func sendKeepAlive(to fd: Int32) throws {
        // ServerControlPacket::KeepAlive is enum variant 3.
        try writeExactly(framedPayload(Data([3, 0, 0, 0])), to: fd,
                         deadline: Date().addingTimeInterval(0.4))
    }

    fileprivate static func sendDecoderConfig(_ parameterSets: Data, codec: VideoCodec,
                                              to fd: Int32) throws {
        try writeExactly(
            framedPayload(decoderConfigPayload(parameterSets: parameterSets, codec: codec)),
            to: fd, deadline: Date().addingTimeInterval(0.4))
    }

    /// Bincode `ServerControlPacket::DecoderConfig(DecoderInitializationConfig
    /// { codec, config_buffer })` (`alvr/packets/src/lib.rs`): variant 1 and
    /// the `CodecType` as little-endian u32, then the buffer as a
    /// little-endian u64 length and bytes.
    static func decoderConfigPayload(parameterSets: Data, codec: VideoCodec) -> Data {
        var payload = Data()
        appendLittleEndian(UInt32(1), to: &payload) // ServerControlPacket::DecoderConfig
        appendLittleEndian(codec.alvrCodecType, to: &payload) // CodecType
        appendLittleEndian(UInt64(parameterSets.count), to: &payload)
        payload.append(parameterSets)
        return payload
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T,
                                                                  to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    fileprivate static func framedPayload(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumPacketBytes else {
            throw BasaltError("Invalid outgoing ALVR control packet length \(payload.count)")
        }
        var packet = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(payload)
        return packet
    }

    private static func readExactly(_ count: Int, from fd: Int32, deadline: Date) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow * 1_000))
            guard remainingMs > 0 else { throw BasaltError("Timed out reading ALVR control packet") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, remainingMs) > 0 else {
                throw BasaltError("Timed out reading ALVR control packet")
            }
            let received = data.withUnsafeMutableBytes { bytes in
                recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            guard received > 0 else {
                if received == 0 { throw BasaltError("ALVR client closed the control connection") }
                if errno == EAGAIN || errno == EINTR { continue }
                throw socketError("Failed reading ALVR control packet")
            }
            offset += received
        }
        return data
    }

    fileprivate static func writeExactly(_ data: Data, to fd: Int32, deadline: Date) throws {
        var offset = 0
        while offset < data.count {
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow * 1_000))
            guard remainingMs > 0 else { throw BasaltError("Timed out writing ALVR control packet") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, remainingMs) > 0 else {
                throw BasaltError("Timed out writing ALVR control packet")
            }
            let sent = data.withUnsafeBytes { bytes in
                send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            guard sent > 0 else {
                if sent < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                throw socketError("Failed writing ALVR control packet")
            }
            offset += sent
        }
    }

    private static func socketError(_ context: String) -> BasaltError {
        BasaltError("\(context): \(String(cString: strerror(errno)))")
    }
}

private extension Data {
    var hexPrefix: String {
        prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

private struct LittleEndianReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }
    var isAtEnd: Bool { offset == data.count }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw BasaltError("Truncated ALVR control packet") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(try readInteger(byteCount: 4))
    }

    mutating func readUInt64() throws -> UInt64 {
        try readInteger(byteCount: 8)
    }

    mutating func readString(maxBytes: Int) throws -> String {
        let length64 = try readUInt64()
        guard length64 <= UInt64(maxBytes) else {
            throw BasaltError("ALVR string exceeds \(maxBytes) bytes")
        }
        let length = Int(length64)
        guard offset + length <= data.count else { throw BasaltError("Truncated ALVR control packet") }
        let bytes = data[offset..<offset + length]
        offset += length
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw BasaltError("ALVR control packet contains invalid UTF-8")
        }
        return value
    }

    mutating func readIPAddress() throws -> String {
        let variant = try readUInt32()
        switch variant {
        case 0:
            return try (0..<4).map { _ in String(try readByte()) }.joined(separator: ".")
        case 1:
            var bytes = [UInt8]()
            for _ in 0..<16 { bytes.append(try readByte()) }
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                throw BasaltError("Invalid IPv6 address in ALVR control packet")
            }
            return String(cString: buffer)
        default:
            throw BasaltError("Unknown ALVR IP address variant \(variant)")
        }
    }

    mutating func readVideoCapabilities() throws -> AlvrVideoCapabilities {
        let width = try readUInt32()
        let height = try readUInt32()
        let count = try readUInt64()
        guard count <= 16_384 else { throw BasaltError("ALVR refresh-rate payload is too large") }

        var refreshRates = [Float]()
        var jsonBytes = [UInt8]()
        for _ in 0..<count {
            let rate = try readFloat32()
            if rate < 0 {
                let byte = -rate
                guard byte <= 255, byte.rounded() == byte else {
                    throw BasaltError("Invalid ALVR capabilities JSON byte")
                }
                jsonBytes.append(UInt8(byte))
            } else {
                refreshRates.append(rate)
            }
        }
        let microphoneSampleRate = try readUInt32()

        var extras: [String: Any] = [:]
        if !jsonBytes.isEmpty {
            guard let object = try JSONSerialization.jsonObject(with: Data(jsonBytes)) as? [String: Any] else {
                throw BasaltError("Invalid ALVR capabilities JSON")
            }
            extras = object
        }
        func bool(_ key: String, default fallback: Bool) -> Bool {
            extras[key] as? Bool ?? fallback
        }
        let gamma = (extras["preferred_encoding_gamma"] as? NSNumber)?.floatValue ?? 1

        return AlvrVideoCapabilities(
            width: width, height: height, refreshRates: refreshRates,
            microphoneSampleRate: microphoneSampleRate,
            supportsFoveatedEncoding: bool("supports_foveated_encoding", default: true),
            supportsHighProfile: bool("encoder_high_profile", default: true),
            supports10Bit: bool("encoder_10_bits", default: true),
            supportsAV1: bool("encoder_av1", default: true),
            prefers10Bit: bool("prefer_10bit", default: false),
            prefersFullRange: bool("prefer_full_range", default: true),
            preferredEncodingGamma: gamma,
            prefersHDR: bool("prefer_hdr", default: false))
    }

    mutating func readFloat32() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    private mutating func readInteger(byteCount: Int) throws -> UInt64 {
        guard offset + byteCount <= data.count else { throw BasaltError("Truncated ALVR control packet") }
        var value: UInt64 = 0
        for index in 0..<byteCount {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        offset += byteCount
        return value
    }
}
