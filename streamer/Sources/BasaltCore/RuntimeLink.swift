import Foundation
import Network
import IOSurface
import CoreVideo
import Security

/// Daemon side of the BasaltVR runtime control socket
/// (docs/DXMT-INTEROP.md §4; wire format in runtime/pe/basalt_control_protocol.h,
/// mirrored here because the constants are trivially small).
///
/// Listens on loopback, writes "<port> <token> <width> <height>" to the control file the
/// launcher hands the game bottle via BASALT_CONTROL, validates the Hello
/// token, retains every registered swapchain IOSurface (IDs are untrusted:
/// dimensions are re-checked after lookup), and surfaces fence-confirmed
/// frames to `onFrame`. One runtime session at a time: a new connection that
/// completes an authenticated Hello replaces the current one (a quick
/// xrDestroySession/xrCreateSession may connect before the old EOF arrives).
public final class RuntimeLink: @unchecked Sendable {
    /// Acknowledges one frame to the runtime, exactly once. Holders must keep
    /// it alive until their reads of the frame's surfaces finish: releasing
    /// the last reference acknowledges the frame, so a forgotten `complete()`
    /// cannot stall every later acknowledgement and starve `xrWaitFrame`.
    public final class FrameConsumption: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?

        fileprivate init(_ action: @escaping @Sendable () -> Void) {
            self.action = action
        }

        deinit {
            complete()
        }

        public func complete() {
            lock.lock()
            let pending = action
            action = nil
            lock.unlock()
            pending?()
        }
    }

    enum MessageType: UInt16, CaseIterable {
        case hello = 1
        case helloAck = 2
        case createSwapchain = 3
        case swapchainAck = 4
        case destroySwapchain = 5
        case destroySwapchainAck = 6
        case frameReady = 7
        case teardown = 8
        case headPose = 9
        case controllerMotion = 10
        case buttonState = 11
        case haptic = 12
        case interactionProfile = 13
        case inputReset = 14
        case viewConfig = 15
        case controllerMask = 16
        case frameConsumed = 17
    }

    public static let protocolVersion: UInt16 = 9
    static let tokenLength = 32
    static let maxMessageLength = 4096
    /// The runtime's largest per-eye view; it ignores a larger configured size.
    public static let maximumViewWidth = 1680
    public static let maximumViewHeight = 1760
    static let maximumRetainedButtonPaths = 64
    /// The runtime's view-config bounds (parseViewConfig in
    /// runtime/pe/control.cpp). It treats a value outside them as a corrupt
    /// connection, so out-of-range calibration must never be sent.
    static let viewConfigIPDRange: ClosedRange<Float> = 0.04...0.09
    static let maximumViewConfigFovAngle: Float = 1.57079633

    public struct FrameView {
        public let swapchainId: UInt64
        public let dxgiFormat: UInt32
        public let imageIndex: UInt32
        public let imageArrayIndex: UInt32
        public let rect: (x: Int32, y: Int32, width: Int32, height: Int32)
        public let surface: IOSurfaceRef
    }

    public struct Frame {
        public let frameNumber: UInt64
        public let displayTime: Int64
        /// Exact ALVR/Quest tracking timestamp selected by the runtime when
        /// it located the views rendered into this frame.
        public let questTrackingTimestampNanoseconds: UInt64
        public let views: [FrameView]
    }

    struct FrameReadyHeader {
        static let byteCount = 28

        let frameNumber: UInt64
        let displayTime: Int64
        let questTrackingTimestampNanoseconds: UInt64
        let viewCount: UInt32
    }

    public struct Swapchain {
        public let id: UInt64
        public let width: UInt32
        public let height: UInt32
        public let dxgiFormat: UInt32
        public let surfaces: [IOSurfaceRef]
    }

    public var onHello: ((_ sessionId: UInt64, _ renderer: String) -> Void)?
    public var onSwapchain: ((Swapchain) -> Void)?
    /// The consumer must invoke `consumed` after it has finished reading the
    /// frame's source IOSurfaces. The callback is one-shot and connection
    /// scoped, so late completions after teardown are harmless.
    public var onFrame: ((_ frame: Frame, _ consumption: FrameConsumption) -> Void)?
    public var onTeardown: (() -> Void)?
    /// A runtime connection was refused (wrong protocol version or token,
    /// malformed Hello). Called on the link's queue with a readable reason.
    public var onProtocolError: ((String) -> Void)?
    /// The streamer prefixes refusal reasons with this on stderr so the
    /// manager can surface them; the game itself only sees a headless session.
    public static let connectionRefusedLogPrefix = "OpenXR runtime connection refused: "
    private var hapticHandler: ((_ hand: AlvrHand, _ durationNanoseconds: UInt64,
                                 _ frequency: Float, _ amplitude: Float) -> Void)?

    private let controlFilePath: String
    private let recommendedViewSize: PerEyeResolution?
    private let queue = DispatchQueue(label: "basalt.runtime-link")
    private let listener: NWListener
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    /// Connections that have not yet sent an authenticated Hello. They never
    /// receive runtime state, and each is dropped after `helloTimeout`.
    private var candidates: [(connection: NWConnection, buffer: Data)] = []
    static let maximumCandidateConnections = 4
    var helloTimeout: DispatchTimeInterval = .seconds(5)
    private var helloDone = false
    private var swapchains: [UInt64: Swapchain] = [:]
    private var token = ""
    private var pendingHeadPose: Data?
    private var headPoseSendInFlight = false
    private var pendingControllerMotions: [AlvrHand: Data] = [:]
    private var controllerMotionSendInFlight = false
    private var nextControllerHand = AlvrHand.left
    private var latestButtonPayloads: [UInt64: Data] = [:]
    private var pendingButtonPayloads: [UInt64: Data] = [:]
    private var buttonSendInFlight = false
    private var latestInteractionProfiles: [AlvrHand: UInt64] = [:]
    private var latestViewConfigPayload: Data?
    private var latestControllerMask: UInt32?
    private var latestControllerMaskPayload: Data?
    private var completedFrameNumbers = Set<UInt64>()
    private var lastAcknowledgedFrameNumber: UInt64 = 0

    public init(
        controlFilePath: String,
        recommendedViewSize: PerEyeResolution? = nil
    ) throws {
        if let size = recommendedViewSize,
           size.width > Self.maximumViewWidth || size.height > Self.maximumViewHeight {
            // The runtime would fall back to its maximum, so the game would
            // render at a different size than the streamer encodes.
            throw BasaltError(
                "Per-eye resolution \(size.width)x\(size.height) exceeds the OpenXR "
                + "runtime's \(Self.maximumViewWidth)x\(Self.maximumViewHeight) maximum")
        }
        self.controlFilePath = controlFilePath
        self.recommendedViewSize = recommendedViewSize
        // FrameConsumed gates the game's xrWaitFrame; never let Nagle hold
        // the tiny ack behind an unacknowledged pose write.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: 0)!)
        listener = try NWListener(using: parameters)
    }

    /// Binds, writes the control file, and begins accepting the runtime.
    public func start() async throws {
        var tokenBytes = [UInt8](repeating: 0, count: Self.tokenLength / 2)
        guard SecRandomCopyBytes(kSecRandomDefault, tokenBytes.count, &tokenBytes)
                == errSecSuccess else {
            throw BasaltError("SecRandomCopyBytes failed")
        }
        token = tokenBytes.map { String(format: "%02x", $0) }.joined()

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                var finished = false
                self.listener.newConnectionHandler = { [weak self] newConnection in
                    self?.accept(newConnection)
                }
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self, !finished else { return }
                    switch state {
                    case .ready:
                        finished = true
                        do {
                            guard let port = self.listener.port?.rawValue else {
                                throw BasaltError("runtime link has no bound port")
                            }
                            // The token is the only authentication for the
                            // loopback control socket, so the file that carries
                            // it must not be world-readable (the launcher points
                            // BASALT_CONTROL at it, often under /tmp). Create it
                            // 0600 in one step so it is never briefly exposed.
                            try? FileManager.default.removeItem(
                                atPath: self.controlFilePath)
                            let controlLine = Self.controlFileLine(
                                port: port, token: self.token,
                                recommendedViewSize: self.recommendedViewSize)
                            guard FileManager.default.createFile(
                                atPath: self.controlFilePath,
                                contents: Data(controlLine.utf8),
                                attributes: [.posixPermissions: 0o600]) else {
                                throw BasaltError(
                                    "Could not write runtime control file at "
                                    + self.controlFilePath)
                            }
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    case .failed(let error):
                        finished = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    static func controlFileLine(
        port: UInt16,
        token: String,
        recommendedViewSize: PerEyeResolution?
    ) -> String {
        guard let size = recommendedViewSize else {
            return "\(port) \(token)\n"
        }
        return "\(port) \(token) \(size.width) \(size.height)\n"
    }

    public func stop() {
        queue.async {
            for candidate in self.candidates { candidate.connection.cancel() }
            self.candidates.removeAll()
            self.dropConnection()
            self.listener.cancel()
            try? FileManager.default.removeItem(atPath: self.controlFilePath)
        }
    }

    /// Publishes ALVR's latest pre-predicted OpenXR head pose. The Quest
    /// timestamp is retained for ordering only; it is a different clock from
    /// the runtime's XrTime. Queue confinement and one-deep replacement keep
    /// tracking from accumulating behind a slow control connection.
    public func publishHeadPose(timestampNanoseconds: UInt64, pose: AlvrHeadPose) {
        guard let payload = Self.headPosePayload(
                timestampNanoseconds: timestampNanoseconds, pose: pose) else {
            return
        }
        queue.async {
            self.pendingHeadPose = payload
            self.pumpHeadPose()
        }
    }

    public func publishControllerMotion(timestampNanoseconds: UInt64, hand: AlvrHand,
                                        motion: AlvrControllerMotion) {
        guard let payload = Self.controllerMotionPayload(
                timestampNanoseconds: timestampNanoseconds, hand: hand,
                motion: motion) else { return }
        queue.async {
            self.pendingControllerMotions[hand] = payload
            self.pumpControllerMotion()
        }
    }

    /// Invalidates controller poses omitted from one authoritative ALVR
    /// tracking packet. Present bits never activate a pose by themselves;
    /// the corresponding motion message remains the source of pose data.
    public func publishControllerMask(timestampNanoseconds: UInt64, activeMask: UInt32) {
        guard let payload = Self.controllerMaskPayload(
                timestampNanoseconds: timestampNanoseconds,
                activeMask: activeMask) else { return }
        queue.async {
            let changed = self.latestControllerMask != activeMask
            self.latestControllerMask = activeMask
            self.latestControllerMaskPayload = payload
            if changed && self.helloDone {
                // Presence transitions must not be coalesced behind a stale
                // pending motion for the same hand.
                self.send(type: .controllerMask, payload: payload)
            }
        }
    }

    public func publishButtons(_ entries: [AlvrButtonEntry]) {
        let payloads = entries.compactMap { entry in
            Self.buttonStatePayload(entry).map { (entry.pathID, $0) }
        }
        guard !payloads.isEmpty else { return }
        queue.async {
            for (pathID, payload) in payloads {
                guard Self.retainButtonPayload(
                        pathID: pathID, payload: payload,
                        in: &self.latestButtonPayloads) else { continue }
                self.pendingButtonPayloads[pathID] = payload
            }
            self.pumpButtonState()
        }
    }

    public func publishInteractionProfile(deviceID: UInt64, profileID: UInt64) {
        // The runtime rejects profile 0 as a protocol error.
        guard let hand = AlvrHand(alvrDeviceID: deviceID), profileID != 0 else { return }
        queue.async {
            self.latestInteractionProfiles[hand] = profileID
            if self.helloDone {
                self.send(type: .interactionProfile,
                          payload: Self.interactionProfilePayload(hand: hand,
                                                                  profileID: profileID))
            }
        }
    }

    /// Publishes the headset's calibrated IPD and asymmetric per-eye FOV.
    /// Retaining the most recent value lets a runtime that connects after the
    /// ALVR control handshake receive the same projection configuration.
    public func publishViewsConfig(_ config: AlvrViewsConfig) {
        guard let payload = Self.viewConfigPayload(config) else { return }
        queue.async {
            self.latestViewConfigPayload = payload
            if self.helloDone {
                self.send(type: .viewConfig, payload: payload)
            }
        }
    }

    /// Invalidates input retained from the current ALVR session. A reset is
    /// ordered after any already-submitted tracking/button writes and before
    /// samples from a replacement session. Head tracking then becomes stale
    /// naturally in the runtime; unsent head/controller samples are discarded.
    public func resetInputs() {
        queue.async {
            self.pendingHeadPose = nil
            self.pendingControllerMotions.removeAll()
            self.nextControllerHand = .left
            self.latestButtonPayloads.removeAll()
            self.pendingButtonPayloads.removeAll()
            self.latestInteractionProfiles.removeAll()
            self.latestControllerMask = nil
            self.latestControllerMaskPayload = nil
            if self.helloDone {
                self.send(type: .inputReset, payload: Data())
            }
        }
    }

    public func onHaptic(
        _ handler: @escaping (_ hand: AlvrHand, _ durationNanoseconds: UInt64,
                              _ frequency: Float, _ amplitude: Float) -> Void
    ) {
        queue.async { self.hapticHandler = handler }
    }

    @discardableResult
    static func retainButtonPayload(
        pathID: UInt64,
        payload: Data,
        in payloads: inout [UInt64: Data],
        capacity: Int = maximumRetainedButtonPaths
    ) -> Bool {
        guard payloads[pathID] != nil || payloads.count < capacity else { return false }
        payloads[pathID] = payload
        return true
    }

    static func controllerSendSelection(
        pending: Set<AlvrHand>, preferred: AlvrHand
    ) -> (hand: AlvrHand, next: AlvrHand)? {
        let other: AlvrHand = preferred == .left ? .right : .left
        if pending.contains(preferred) { return (preferred, other) }
        if pending.contains(other) { return (other, preferred) }
        return nil
    }

    static func headPosePayload(
        timestampNanoseconds: UInt64,
        pose: AlvrHeadPose
    ) -> Data? {
        let values = [
            pose.orientationX, pose.orientationY, pose.orientationZ, pose.orientationW,
            pose.positionX, pose.positionY, pose.positionZ,
        ]
        guard values.allSatisfy(\.isFinite) else { return nil }
        let normSquared = values[0] * values[0] + values[1] * values[1]
            + values[2] * values[2] + values[3] * values[3]
        guard normSquared >= 0.25, normSquared <= 2.25 else { return nil }
        let inverseNorm = 1 / sqrt(normSquared)

        var payload = Data()
        payload.appendU64(timestampNanoseconds)
        for value in values.prefix(4) { payload.appendF32(value * inverseNorm) }
        for value in values.suffix(3) { payload.appendF32(value) }
        return payload
    }

    static func controllerMotionPayload(
        timestampNanoseconds: UInt64, hand: AlvrHand,
        motion: AlvrControllerMotion
    ) -> Data? {
        let pose = motion.pose
        let values = [
            pose.orientationX, pose.orientationY, pose.orientationZ, pose.orientationW,
            pose.positionX, pose.positionY, pose.positionZ,
            motion.linearVelocityX, motion.linearVelocityY, motion.linearVelocityZ,
            motion.angularVelocityX, motion.angularVelocityY, motion.angularVelocityZ,
        ]
        guard values.allSatisfy(\.isFinite) else { return nil }
        let normSquared = values[0] * values[0] + values[1] * values[1]
            + values[2] * values[2] + values[3] * values[3]
        guard normSquared >= 0.25, normSquared <= 2.25 else { return nil }
        let inverseNorm = 1 / sqrt(normSquared)

        var payload = Data()
        payload.appendU64(timestampNanoseconds)
        payload.appendU32(hand.rawValue)
        payload.appendU32(0)
        for value in values.prefix(4) { payload.appendF32(value * inverseNorm) }
        for value in values.dropFirst(4) { payload.appendF32(value) }
        return payload
    }

    static func controllerMaskPayload(
        timestampNanoseconds: UInt64, activeMask: UInt32
    ) -> Data? {
        guard activeMask & ~UInt32(3) == 0 else { return nil }
        var payload = Data()
        payload.appendU64(timestampNanoseconds)
        payload.appendU32(activeMask)
        payload.appendU32(0)
        return payload
    }

    static func buttonStatePayload(_ entry: AlvrButtonEntry) -> Data? {
        // The runtime rejects path 0 as a protocol error.
        guard entry.pathID != 0 else { return nil }
        var payload = Data()
        payload.appendU64(entry.pathID)
        switch entry.value {
        case .binary(let value):
            payload.appendU32(0)
            payload.appendF32(value ? 1 : 0)
        case .scalar(let value):
            guard value.isFinite else { return nil }
            payload.appendU32(1)
            payload.appendF32(value)
        }
        return payload
    }

    static func interactionProfilePayload(hand: AlvrHand, profileID: UInt64) -> Data {
        var payload = Data()
        payload.appendU32(hand.rawValue)
        payload.appendU64(profileID)
        return payload
    }

    static func viewConfigPayload(_ config: AlvrViewsConfig) -> Data? {
        guard config.fov.count == 2,
              viewConfigIPDRange.contains(config.ipdMeters) else { return nil }
        let limit = maximumViewConfigFovAngle
        guard config.fov.allSatisfy({ fov in
            fov.left < fov.right && fov.down < fov.up
                && fov.left >= -limit && fov.right <= limit
                && fov.down >= -limit && fov.up <= limit
        }) else { return nil }
        let values = config.fov.flatMap { [$0.left, $0.right, $0.up, $0.down] }

        var payload = Data()
        payload.appendF32(config.ipdMeters)
        for value in values { payload.appendF32(value) }
        return payload
    }

    // MARK: - connection handling (all on `queue`)

    private func accept(_ newConnection: NWConnection) {
        // Unauthenticated connections cannot hold a slot the runtime needs:
        // the oldest is dropped when too many are waiting for their Hello.
        if candidates.count >= Self.maximumCandidateConnections {
            dropCandidate(candidates[0].connection)
        }
        candidates.append((newConnection, Data()))
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard case .failed = state, let self, let newConnection else { return }
            self.dropCandidate(newConnection)
            // A replaced connection's late failure must not drop its
            // successor (e.g. a quick OpenXR session restart).
            self.onQueue(ifCurrent: newConnection) { self.dropConnection() }
        }
        queue.asyncAfter(deadline: .now() + helloTimeout) { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.dropCandidate(newConnection)
        }
        newConnection.start(queue: queue)
        receiveHello(on: newConnection)
    }

    private func dropCandidate(_ candidate: NWConnection) {
        guard let index = candidates.firstIndex(where: { $0.connection === candidate }) else {
            return
        }
        candidates.remove(at: index)
        candidate.cancel()
    }

    /// Reads a candidate until its first message, which must be an
    /// authenticated Hello. Only then may it replace the live connection.
    private func receiveHello(on candidate: NWConnection) {
        candidate.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self, weak candidate] data, _, isComplete, error in
            guard let self, let candidate,
                  let index = self.candidates.firstIndex(where: { $0.connection === candidate })
            else { return }
            if let data { self.candidates[index].buffer.append(data) }
            switch Self.helloFrame(in: self.candidates[index].buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    self.dropCandidate(candidate)
                } else {
                    self.receiveHello(on: candidate)
                }
            case .invalid:
                self.dropCandidate(candidate)
            case .hello(let payload, let remaining):
                self.candidates.remove(at: index)
                let verdict = Self.helloVerdict(payload, token: self.token)
                guard case .accept(let sessionId, let renderer) = verdict else {
                    if case .refuse(let reason) = verdict { self.onProtocolError?(reason) }
                    candidate.cancel()
                    return
                }
                self.promote(candidate, sessionId: sessionId, renderer: renderer,
                             remaining: remaining)
                if isComplete || error != nil {
                    self.dropConnection()
                } else {
                    self.receiveMore()
                }
            }
        }
    }

    enum HelloFrame: Equatable {
        case incomplete
        /// The first message is malformed or not a Hello.
        case invalid
        case hello(payload: Data, remaining: Data)
    }

    static func helloFrame(in buffer: Data) -> HelloFrame {
        guard buffer.count >= 6 else { return .incomplete }
        let length = Int(buffer.readU32(at: 0))
        guard length >= 2, length <= maxMessageLength,
              buffer.readU16(at: 4) == MessageType.hello.rawValue else {
            return .invalid
        }
        guard buffer.count >= 4 + length else { return .incomplete }
        let start = buffer.startIndex
        return .hello(
            payload: buffer.subdata(in: (start + 6)..<(start + 4 + length)),
            remaining: buffer.subdata(in: (start + 4 + length)..<buffer.endIndex))
    }

    private func promote(_ candidate: NWConnection, sessionId: UInt64, renderer: String,
                         remaining: Data) {
        dropConnection()
        connection = candidate
        receiveBuffer = remaining
        completeHello(sessionId: sessionId, renderer: renderer)
        if !drainMessages() { dropConnection() }
    }

    /// Runs `body` on `queue` only while `expected` is still the live
    /// connection. Late completions from a dropped connection (failures,
    /// sends, released frames) must never act on its successor.
    private func onQueue(ifCurrent expected: NWConnection, _ body: @escaping () -> Void) {
        queue.async { [weak self, weak expected] in
            guard let self, let expected, self.connection === expected else { return }
            body()
        }
    }

    private func dropConnection() {
        connection?.cancel()
        connection = nil
        // Dropping the dictionary releases every surface retain.
        swapchains.removeAll()
        receiveBuffer.removeAll()
        pendingHeadPose = nil
        headPoseSendInFlight = false
        pendingControllerMotions.removeAll()
        controllerMotionSendInFlight = false
        nextControllerHand = .left
        pendingButtonPayloads.removeAll()
        buttonSendInFlight = false
        completedFrameNumbers.removeAll()
        lastAcknowledgedFrameNumber = 0
        if helloDone {
            helloDone = false
            onTeardown?()
        }
    }

    private func receiveMore() {
        guard let activeConnection = connection else { return }
        activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self, weak activeConnection] data, _, isComplete, error in
            // Cancelling a dropped connection completes its outstanding
            // receive with an error; that completion must neither drop nor
            // feed bytes into a newer connection.
            guard let self, let activeConnection,
                  self.connection === activeConnection else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                if !self.drainMessages() {
                    self.dropConnection()
                    return
                }
            }
            if isComplete || error != nil {
                self.dropConnection()
                return
            }
            self.receiveMore()
        }
    }

    /// Extracts complete length-framed messages; false on protocol error.
    private func drainMessages() -> Bool {
        while receiveBuffer.count >= 6 {
            let length = receiveBuffer.readU32(at: 0)
            guard length >= 2, length <= Self.maxMessageLength else { return false }
            guard receiveBuffer.count >= 4 + Int(length) else { return true }
            let type = receiveBuffer.readU16(at: 4)
            let payload = receiveBuffer.subdata(in: 6..<(4 + Int(length)))
            receiveBuffer.removeSubrange(0..<(4 + Int(length)))
            guard handle(type: type, payload: payload) else { return false }
        }
        return true
    }

    private func send(type: MessageType, payload: Data) {
        var message = Data()
        message.appendU32(UInt32(2 + payload.count))
        message.appendU16(type.rawValue)
        message.append(payload)
        connection?.send(content: message, completion: .idempotent)
    }

    private func pumpHeadPose() {
        guard helloDone, !headPoseSendInFlight,
              let connection, let payload = pendingHeadPose else {
            return
        }
        pendingHeadPose = nil
        headPoseSendInFlight = true
        var message = Data()
        message.appendU32(UInt32(2 + payload.count))
        message.appendU16(MessageType.headPose.rawValue)
        message.append(payload)
        connection.send(content: message, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.onQueue(ifCurrent: connection) {
                self.headPoseSendInFlight = false
                if error != nil { self.dropConnection() } else { self.pumpHeadPose() }
            }
        })
    }

    private func pumpControllerMotion() {
        guard helloDone, !controllerMotionSendInFlight, let connection,
              let selection = Self.controllerSendSelection(
                  pending: Set(pendingControllerMotions.keys),
                  preferred: nextControllerHand),
              let payload = pendingControllerMotions.removeValue(forKey: selection.hand) else {
            return
        }
        nextControllerHand = selection.next
        controllerMotionSendInFlight = true
        var message = Data()
        message.appendU32(UInt32(2 + payload.count))
        message.appendU16(MessageType.controllerMotion.rawValue)
        message.append(payload)
        connection.send(content: message, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.onQueue(ifCurrent: connection) {
                self.controllerMotionSendInFlight = false
                if error != nil { self.dropConnection() } else { self.pumpControllerMotion() }
            }
        })
    }

    private func pumpButtonState() {
        guard helloDone, !buttonSendInFlight, let connection,
              let (pathID, payload) = pendingButtonPayloads.first else { return }
        pendingButtonPayloads.removeValue(forKey: pathID)
        buttonSendInFlight = true
        var message = Data()
        message.appendU32(UInt32(2 + payload.count))
        message.appendU16(MessageType.buttonState.rawValue)
        message.append(payload)
        connection.send(content: message, completion: .contentProcessed {
            [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.onQueue(ifCurrent: connection) {
                self.buttonSendInFlight = false
                if error != nil { self.dropConnection() } else { self.pumpButtonState() }
            }
        })
    }

    private func handle(type: UInt16, payload: Data) -> Bool {
        guard helloDone, let message = MessageType(rawValue: type) else { return false }
        switch message {
        case .createSwapchain: return handleCreateSwapchain(payload)
        case .destroySwapchain: return handleDestroySwapchain(payload)
        case .frameReady: return handleFrameReady(payload)
        case .haptic: return handleHaptic(payload)
        case .teardown:
            dropConnection()
            return true
        default:
            return false
        }
    }

    private func completeHello(sessionId: UInt64, renderer: String) {
        helloDone = true
        var ack = Data()
        ack.appendU16(Self.protocolVersion)
        send(type: .helloAck, payload: ack)
        onHello?(sessionId, renderer)
        pumpHeadPose()
        pumpControllerMotion()
        pendingButtonPayloads = latestButtonPayloads
        pumpButtonState()
        for (hand, profileID) in latestInteractionProfiles {
            send(type: .interactionProfile,
                 payload: Self.interactionProfilePayload(hand: hand, profileID: profileID))
        }
        if let latestViewConfigPayload {
            send(type: .viewConfig, payload: latestViewConfigPayload)
        }
        if let latestControllerMaskPayload {
            send(type: .controllerMask, payload: latestControllerMaskPayload)
        }
    }

    enum HelloVerdict: Equatable {
        case accept(sessionId: UInt64, renderer: String)
        /// Not authenticated by the control token: drop without reporting,
        /// so an arbitrary local process cannot raise a user-facing alert.
        case ignore
        /// An authenticated runtime that cannot start a session.
        case refuse(String)
    }

    /// Whether a Hello may start a session. The token is checked first; it
    /// sits at the same offset in every protocol version. A version mismatch
    /// from an authenticated runtime means the bottle's DLL and this streamer
    /// come from different builds; the game then runs headless (a black
    /// headset), so the reason must reach the session log.
    static func helloVerdict(_ payload: Data, token: String) -> HelloVerdict {
        let headerLength = 2 + tokenLength + 8 + 2
        guard payload.count >= 2 + tokenLength,
              String(data: payload.subdata(in: 2..<(2 + tokenLength)),
                     encoding: .ascii) == token else {
            return .ignore
        }
        let version = payload.readU16(at: 0)
        guard version == protocolVersion else {
            return .refuse(
                "OpenXR runtime speaks control protocol v\(version), but this streamer "
                + "speaks v\(protocolVersion): the bottle's basalt_openxr.dll is from a "
                + "different build (from source, run `make runtime-build`, then relaunch)")
        }
        guard payload.count >= headerLength,
              payload.count == headerLength
                + Int(payload.readU16(at: 2 + tokenLength + 8)) else {
            return .refuse("runtime sent a malformed Hello")
        }
        return .accept(
            sessionId: payload.readU64(at: 2 + tokenLength),
            renderer: String(data: payload.subdata(in: headerLength..<payload.count),
                             encoding: .utf8) ?? "")
    }

    private func handleCreateSwapchain(_ payload: Data) -> Bool {
        guard payload.count >= 24 else { return false }
        let id = payload.readU64(at: 0)
        let width = payload.readU32(at: 8)
        let height = payload.readU32(at: 12)
        let format = payload.readU32(at: 16)
        let imageCount = payload.readU32(at: 20)
        guard imageCount > 0, imageCount <= 8,
              Self.isStreamableSwapchainFormat(
                  dxgiFormat: format,
                  iosurfacePixelFormat: kCVPixelFormatType_32BGRA),
              payload.count == 24 + Int(imageCount) * 4,
              swapchains[id] == nil else {
            return false
        }
        var surfaces: [IOSurfaceRef] = []
        for index in 0..<Int(imageCount) {
            let surfaceId = payload.readU32(at: 24 + index * 4)
            guard let surface = IOSurfaceLookup(surfaceId),
                  IOSurfaceGetWidth(surface) == Int(width),
                  IOSurfaceGetHeight(surface) == Int(height),
                  Self.isStreamableSwapchainFormat(
                      dxgiFormat: format,
                      iosurfacePixelFormat: IOSurfaceGetPixelFormat(surface)) else {
                return false
            }
            surfaces.append(surface)
        }
        let swapchain = Swapchain(
            id: id, width: width, height: height, dxgiFormat: format,
            surfaces: surfaces)
        swapchains[id] = swapchain
        var ack = Data()
        ack.appendU64(id)
        ack.appendU32(1)  // generation
        send(type: .swapchainAck, payload: ack)
        onSwapchain?(swapchain)
        return true
    }

    private func handleDestroySwapchain(_ payload: Data) -> Bool {
        guard payload.count == 8 else { return false }
        let id = payload.readU64(at: 0)
        guard swapchains.removeValue(forKey: id) != nil else { return false }
        send(type: .destroySwapchainAck, payload: payload)
        return true
    }

    private func handleFrameReady(_ payload: Data) -> Bool {
        guard let header = Self.frameReadyHeader(from: payload) else { return false }
        var views: [FrameView] = []
        for index in 0..<Int(header.viewCount) {
            let base = FrameReadyHeader.byteCount + index * 76
            let swapchainId = payload.readU64(at: base)
            let imageIndex = payload.readU32(at: base + 8)
            let imageArrayIndex = payload.readU32(at: base + 12)
            let rect = (
                x: Int32(bitPattern: payload.readU32(at: base + 16)),
                y: Int32(bitPattern: payload.readU32(at: base + 20)),
                width: Int32(bitPattern: payload.readU32(at: base + 24)),
                height: Int32(bitPattern: payload.readU32(at: base + 28)))
            guard let swapchain = swapchains[swapchainId],
                  imageIndex < UInt32(swapchain.surfaces.count) else {
                return false
            }
            views.append(FrameView(
                swapchainId: swapchainId,
                dxgiFormat: swapchain.dxgiFormat,
                imageIndex: imageIndex,
                imageArrayIndex: imageArrayIndex,
                rect: rect,
                surface: swapchain.surfaces[Int(imageIndex)]))
        }
        let frame = Frame(
            frameNumber: header.frameNumber,
            displayTime: header.displayTime,
            questTrackingTimestampNanoseconds: header.questTrackingTimestampNanoseconds,
            views: views)
        guard let onFrame else {
            markFrameConsumed(header.frameNumber)
            return true
        }
        let activeConnection = connection
        let consumption = FrameConsumption { [weak self, weak activeConnection] in
            guard let self, let activeConnection else { return }
            self.onQueue(ifCurrent: activeConnection) {
                guard self.helloDone else { return }
                self.markFrameConsumed(header.frameNumber)
            }
        }
        onFrame(frame, consumption)
        return true
    }

    private func markFrameConsumed(_ frameNumber: UInt64) {
        guard frameNumber > lastAcknowledgedFrameNumber else { return }
        completedFrameNumbers.insert(frameNumber)
        for acknowledged in Self.orderedAcknowledgements(
                completed: &completedFrameNumbers,
                lastAcknowledged: &lastAcknowledgedFrameNumber) {
            var payload = Data()
            payload.appendU64(acknowledged)
            send(type: .frameConsumed, payload: payload)
        }
    }

    static func orderedAcknowledgements(
        completed: inout Set<UInt64>,
        lastAcknowledged: inout UInt64
    ) -> [UInt64] {
        var ready: [UInt64] = []
        while completed.remove(lastAcknowledged + 1) != nil {
            lastAcknowledged += 1
            ready.append(lastAcknowledged)
        }
        return ready
    }

    static func frameReadyHeader(from payload: Data) -> FrameReadyHeader? {
        guard payload.count >= FrameReadyHeader.byteCount else { return nil }
        let viewCount = payload.readU32(at: 24)
        guard viewCount > 0, viewCount <= 2,
              payload.count == FrameReadyHeader.byteCount + Int(viewCount) * 76 else {
            return nil
        }
        return FrameReadyHeader(
            frameNumber: payload.readU64(at: 0),
            displayTime: Int64(bitPattern: payload.readU64(at: 8)),
            questTrackingTimestampNanoseconds: payload.readU64(at: 16),
            viewCount: viewCount)
    }

    /// The current native compose/encode path is zero-copy BGRA. DXMT can
    /// allocate RGBA IOSurfaces, but CoreVideo cannot wrap that layout.
    static func isStreamableSwapchainFormat(
            dxgiFormat: UInt32, iosurfacePixelFormat: OSType) -> Bool {
        let isBgraDxgi = dxgiFormat == 87 || dxgiFormat == 91
        return isBgraDxgi && iosurfacePixelFormat == kCVPixelFormatType_32BGRA
    }

    private func handleHaptic(_ payload: Data) -> Bool {
        guard payload.count == 20,
              let hand = AlvrHand(rawValue: payload.readU32(at: 0)) else {
            return false
        }
        let duration = payload.readU64(at: 4)
        let frequency = payload.readF32(at: 12)
        let amplitude = payload.readF32(at: 16)
        guard frequency.isFinite, frequency >= 0,
              amplitude.isFinite, amplitude >= 0, amplitude <= 1 else {
            return false
        }
        hapticHandler?(hand, duration, frequency, amplitude)
        return true
    }
}

// MARK: - little-endian Data helpers

private extension Data {
    func readU16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) |
            (UInt16(self[startIndex + offset + 1]) << 8)
    }
    func readU32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in (0..<4).reversed() {
            value = (value << 8) | UInt32(self[startIndex + offset + i])
        }
        return value
    }
    func readU64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in (0..<8).reversed() {
            value = (value << 8) | UInt64(self[startIndex + offset + i])
        }
        return value
    }
    func readF32(at offset: Int) -> Float {
        Float(bitPattern: readU32(at: offset))
    }
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }
    mutating func appendU32(_ value: UInt32) {
        for i in 0..<4 { append(UInt8((value >> (8 * UInt32(i))) & 0xff)) }
    }
    mutating func appendU64(_ value: UInt64) {
        for i in 0..<8 { append(UInt8((value >> (8 * UInt64(i))) & 0xff)) }
    }
    mutating func appendF32(_ value: Float) {
        appendU32(value.bitPattern)
    }
}
