import Foundation

/// One live ALVR client session as the supervisor sees it: something that
/// ends exactly once and can be closed from the streamer side.
public protocol AlvrLiveSession: AnyObject, Sendable {
    /// Calls `handler` once with the reason the session ended. Installing
    /// the handler after the end still reports it immediately.
    func onEnded(_ handler: @escaping @Sendable (_ reason: String) -> Void)
    /// Ends the session from the streamer side. Idempotent; reports
    /// "closed by Basalt" to `onEnded` handlers if nothing ended it first.
    func close()
}

/// The Quest replied StreamReady but never opened its tracking uplink.
public struct AlvrTrackingTimeoutError: LocalizedError {
    /// Why the wait ended early, when the session closed before the timeout.
    public let detail: String?

    public init(detail: String? = nil) {
        self.detail = detail
    }

    public var errorDescription: String? {
        "Quest reported StreamReady but sent no tracking timestamps"
            + (detail.map { " (\($0))" } ?? "")
            + "; keep the headset awake with ALVR in the foreground, then retry"
    }
}

/// What the streamer asks for in one ALVR handshake.
public struct AlvrClientSessionRequest: Sendable {
    public var host: String
    public var controlPort: UInt16
    public var streamPort: UInt16
    public var localStreamPort: UInt16
    public var wired: Bool
    public var expectedProtocolId: UInt64?
    public var requestedViewWidth: UInt32
    public var requestedViewHeight: UInt32
    public var preferredRefreshRate: Float
    public var latencyPreset: StreamLatencyPreset
    public var controllerPrediction: ControllerPrediction
    public var codec: VideoCodec
    public var trackingTimeoutNanoseconds: UInt64

    public init(host: String,
                controlPort: UInt16 = AlvrDiscoveryListener.alvrPort,
                streamPort: UInt16 = AlvrVideoStreamSender.defaultPort,
                localStreamPort: UInt16 = AlvrVideoStreamSender.defaultPort,
                wired: Bool,
                expectedProtocolId: UInt64? = nil,
                requestedViewWidth: UInt32,
                requestedViewHeight: UInt32,
                preferredRefreshRate: Float,
                latencyPreset: StreamLatencyPreset,
                controllerPrediction: ControllerPrediction,
                codec: VideoCodec = .h264,
                trackingTimeoutNanoseconds: UInt64 = 10_000_000_000) {
        self.codec = codec
        self.host = host
        self.controlPort = controlPort
        self.streamPort = streamPort
        self.localStreamPort = localStreamPort
        self.wired = wired
        self.expectedProtocolId = expectedProtocolId
        self.requestedViewWidth = requestedViewWidth
        self.requestedViewHeight = requestedViewHeight
        self.preferredRefreshRate = preferredRefreshRate
        self.latencyPreset = latencyPreset
        self.controllerPrediction = controllerPrediction
        self.trackingTimeoutNanoseconds = trackingTimeoutNanoseconds
    }
}

/// Ties one ALVR control connection to its stream socket. Either side
/// failing ends the whole session: the control socket reaching EOF or going
/// silent, or the USB stream failing a write (Broken pipe) or closing.
public final class AlvrClientSession: AlvrLiveSession, @unchecked Sendable {
    public let control: AlvrSessionHandshakeResult
    public let stream: AlvrVideoStreamSender
    private let lock = NSLock()
    private var endReason: String?
    private var endHandlers: [@Sendable (String) -> Void] = []

    /// Takes ownership of `stream.onTransportClosed` and the control
    /// session's disconnect handler.
    public init(control: AlvrSessionHandshakeResult, stream: AlvrVideoStreamSender) {
        self.control = control
        self.stream = stream
        control.onDisconnect { [weak self] reason in self?.end(reason: reason) }
        stream.onTransportClosed = { [weak self] reason in self?.end(reason: reason) }
    }

    /// Performs the ALVR handshake (StreamConfig, StartStream, StreamReady),
    /// connects the stream socket, lets `prepare` install its callbacks, and
    /// returns once the Quest's tracking uplink is flowing. Everything opened
    /// here is closed again if a later step fails.
    public static func connect(
        _ request: AlvrClientSessionRequest,
        prepare: (_ control: AlvrSessionHandshakeResult,
                  _ stream: AlvrVideoStreamSender) throws -> Void = { _, _ in }
    ) async throws -> AlvrClientSession {
        let handshake = try await AlvrControlProbe.negotiateSession(
            host: request.host,
            port: request.controlPort,
            requestedViewWidth: request.requestedViewWidth,
            requestedViewHeight: request.requestedViewHeight,
            preferredRefreshRate: request.preferredRefreshRate,
            latencyPreset: request.latencyPreset,
            wired: request.wired,
            controllerPrediction: request.controllerPrediction,
            codec: request.codec)
        do {
            guard case .accepted(let protocolId, _, _, _) = handshake.clientState else {
                throw BasaltError("ALVR headset is in standby")
            }
            if let expected = request.expectedProtocolId, protocolId != expected {
                throw BasaltError("ALVR protocol mismatch between discovery and control packet")
            }
            guard handshake.negotiatedSettings != nil else {
                throw BasaltError("ALVR negotiation did not produce streaming settings")
            }
            guard handshake.streamReady else {
                throw BasaltError("Quest did not report StreamReady")
            }
        } catch {
            handshake.close()
            throw error
        }

        let stream: AlvrVideoStreamSender
        do {
            stream = try AlvrVideoStreamSender(
                host: request.host, remotePort: request.streamPort,
                localPort: request.localStreamPort,
                transport: request.wired ? .tcp : .udp)
        } catch {
            handshake.close()
            throw error
        }
        let session = AlvrClientSession(control: handshake, stream: stream)
        do {
            try prepare(handshake, stream)
            // StreamReady means the client's control state advanced, but an
            // ALVR client left stale by a prior wired session can accept both
            // TCP connections without sending its tracking uplink. Video
            // headers must use the Quest clock, so tracking is part of
            // connection readiness.
            let deadline = DispatchTime.now().uptimeNanoseconds
                &+ request.trackingTimeoutNanoseconds
            while stream.timestampForVideoFrame() == nil {
                if let reason = session.endedReason {
                    throw AlvrTrackingTimeoutError(detail: "session ended: \(reason)")
                }
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw AlvrTrackingTimeoutError()
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            session.close()
            throw error
        }
        return session
    }

    public var endedReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return endReason
    }

    public func onEnded(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        guard let endReason else {
            endHandlers.append(handler)
            lock.unlock()
            return
        }
        lock.unlock()
        handler(endReason)
    }

    public func close() {
        end(reason: "closed by Basalt")
        stream.close()
        control.close()
    }

    private func end(reason: String) {
        lock.lock()
        guard endReason == nil else {
            lock.unlock()
            return
        }
        endReason = reason
        let handlers = endHandlers
        endHandlers.removeAll()
        lock.unlock()
        for handler in handlers { handler(reason) }
    }
}

/// Keeps the streamer attached to whichever ALVR client shows up: it
/// connects, watches the live session, and when the session ends (Quest
/// asleep, ALVR closed, cable or Wi-Fi lost) reports it, closes it, and goes
/// back to connecting. The OpenXR runtime and the game never see this; they
/// keep running while no client is attached.
public final class AlvrSessionSupervisor: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case connecting(attempt: Int)
        case streaming(generation: Int)
        case waitingToReconnect
        case stopped
    }

    public typealias Connect = @Sendable (_ attempt: Int) async throws -> AlvrLiveSession

    /// Called on the supervisor task. Set these before `start`.
    public var onStateChange: (@Sendable (State) -> Void)?
    public var onSessionStarted: (@Sendable (_ session: AlvrLiveSession, _ generation: Int) -> Void)?
    /// Runs before the ended session is closed, so callers can detach it
    /// from media callbacks first.
    public var onSessionEnded: (@Sendable (_ session: AlvrLiveSession, _ reason: String) -> Void)?
    public var onConnectFailed: (@Sendable (_ error: Error, _ attempt: Int) -> Void)?
    /// Runs after a session ended and after every failed attempt, before the
    /// retry delay (for example to re-create `adb forward` ports).
    public var beforeReconnect: (@Sendable (_ failedAttempts: Int) async -> Void)?

    private let connect: Connect
    private let initialAttemptLimit: Int?
    private let isFatalBeforeFirstSession: @Sendable (Error) -> Bool
    private let retryDelayNanoseconds: UInt64
    private let reconnectDelayNanoseconds: UInt64
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var activeSession: AlvrLiveSession?
    private var firstSessionContinuation: CheckedContinuation<Void, Error>?
    private var firstSessionResult: Result<Void, Error>?
    private var currentState = State.idle

    /// - Parameters:
    ///   - initialAttemptLimit: failed attempts allowed before the first
    ///     session streams (nil: unlimited). After one session has streamed,
    ///     the supervisor retries forever so a sleeping headset can return.
    ///   - isFatalBeforeFirstSession: errors that end startup immediately.
    public init(initialAttemptLimit: Int? = nil,
                retryDelayNanoseconds: UInt64 = 1_000_000_000,
                reconnectDelayNanoseconds: UInt64 = 500_000_000,
                isFatalBeforeFirstSession: @escaping @Sendable (Error) -> Bool = { _ in false },
                connect: @escaping Connect) {
        self.initialAttemptLimit = initialAttemptLimit
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.reconnectDelayNanoseconds = reconnectDelayNanoseconds
        self.isFatalBeforeFirstSession = isFatalBeforeFirstSession
        self.connect = connect
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    /// Starts the supervisor loop on a background task and returns at once.
    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        Task.detached(priority: .userInitiated) { [self] in await run() }
    }

    /// Starts the loop and returns once the first session streams. Throws
    /// when startup gives up (attempt limit or a fatal error); the loop has
    /// then stopped.
    public func startAndWaitForFirstSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let firstSessionResult {
                lock.unlock()
                continuation.resume(with: firstSessionResult)
                return
            }
            firstSessionContinuation = continuation
            lock.unlock()
            start()
        }
    }

    /// Stops reconnecting and closes the live session, if any.
    public func stop() {
        lock.lock()
        stopped = true
        let session = activeSession
        lock.unlock()
        session?.close()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Records the live session so `stop()` can close it. Returns false (and
    /// records nothing) when a stop was already requested.
    @discardableResult
    private func adoptActiveSession(_ session: AlvrLiveSession?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if session != nil, stopped { return false }
        activeSession = session
        return true
    }

    private func setState(_ state: State) {
        lock.lock()
        currentState = state
        lock.unlock()
        onStateChange?(state)
    }

    private func finishStartup(_ result: Result<Void, Error>) {
        lock.lock()
        guard firstSessionResult == nil else {
            lock.unlock()
            return
        }
        firstSessionResult = result
        let continuation = firstSessionContinuation
        firstSessionContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func run() async {
        var failedAttempts = 0
        var generation = 0
        while !isStopped {
            setState(.connecting(attempt: failedAttempts + 1))
            let session: AlvrLiveSession
            do {
                session = try await connect(failedAttempts + 1)
            } catch {
                failedAttempts += 1
                if isStopped { break }
                if generation == 0,
                   isFatalBeforeFirstSession(error)
                    || initialAttemptLimit.map({ failedAttempts >= $0 }) == true {
                    setState(.stopped)
                    finishStartup(.failure(error))
                    return
                }
                onConnectFailed?(error, failedAttempts)
                setState(.waitingToReconnect)
                await beforeReconnect?(failedAttempts)
                await pause(retryDelayNanoseconds)
                continue
            }

            guard adoptActiveSession(session) else {
                session.close()
                break
            }
            failedAttempts = 0
            generation += 1
            setState(.streaming(generation: generation))
            onSessionStarted?(session, generation)
            finishStartup(.success(()))

            let reason = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                session.onEnded { continuation.resume(returning: $0) }
            }
            adoptActiveSession(nil)
            onSessionEnded?(session, reason)
            session.close()
            if isStopped { break }
            setState(.waitingToReconnect)
            await beforeReconnect?(0)
            await pause(reconnectDelayNanoseconds)
        }
        setState(.stopped)
        finishStartup(.failure(BasaltError("ALVR session supervisor stopped")))
    }

    /// Sleeps in short steps so `stop()` is honored promptly.
    private func pause(_ nanoseconds: UInt64) async {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ nanoseconds
        while !isStopped, DispatchTime.now().uptimeNanoseconds < deadline {
            let remaining = deadline &- DispatchTime.now().uptimeNanoseconds
            try? await Task.sleep(nanoseconds: min(remaining, 50_000_000))
        }
    }
}

/// Hands the newest ALVR discovery beacon to the Wi-Fi connect loop. The
/// client keeps announcing itself while it waits for a server, so after a
/// disconnect the next beacon starts the next handshake; beacons that arrive
/// while a session streams are ignored.
public final class AlvrBeaconMailbox: @unchecked Sendable {
    public struct Announcement: Equatable, Sendable {
        public let beacon: AlvrBeacon
        public let ip: String

        public init(beacon: AlvrBeacon, ip: String) {
            self.beacon = beacon
            self.ip = ip
        }
    }

    private let lock = NSLock()
    private var latest: Announcement?
    private var waiter: CheckedContinuation<Announcement?, Never>?
    private var closed = false

    public init() {}

    public func post(_ announcement: Announcement) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: announcement)
            return
        }
        latest = announcement
        lock.unlock()
    }

    /// Waits for a beacon that arrives after this call (or one pending from
    /// before a waiter existed). Returns nil once the mailbox is closed.
    public func next() async -> Announcement? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            if let latest {
                self.latest = nil
                lock.unlock()
                continuation.resume(returning: latest)
                return
            }
            let previous = waiter
            waiter = continuation
            lock.unlock()
            previous?.resume(returning: nil)
        }
    }

    /// Drops a beacon queued while a session was streaming, so a stale
    /// announcement does not trigger an immediate reconnect attempt.
    public func discardPending() {
        lock.lock()
        latest = nil
        lock.unlock()
    }

    public func close() {
        lock.lock()
        closed = true
        latest = nil
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }
}
