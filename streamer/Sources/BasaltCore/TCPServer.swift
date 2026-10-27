import Foundation
import Network

/// Minimal TCP fan-out server: every connected client receives the raw
/// Annex-B H.264 byte stream.
///
/// This is the M1 stand-in for ALVR's transport (which packetizes NALs over
/// its own protocol with time-sync and retransmission); the interface —
/// "broadcast encoded frames, tell me when someone connects" — is the same
/// one the ALVR bridge will implement in M2.
///
/// Hardening:
/// - binds only to `bindHost` (loopback by default, see StreamerOptions)
/// - caps concurrent clients
/// - drops clients whose send queue falls too far behind instead of
///   buffering the stream for them without bound
public final class TCPServer: @unchecked Sendable {
    public var onClientConnected: (() -> Void)?
    /// Listener failures (e.g. the port is already in use) arrive
    /// asynchronously; without a handler they would be silent.
    public var onFailure: ((Error) -> Void)?

    private static let maxClients = 8
    // ~3 s of stream at the default 20 Mbps. A client this far behind
    // will never catch up in real time; kicking it beats buffering.
    private static let maxPendingBytesPerClient = 8 * 1024 * 1024

    private let listener: NWListener
    private let queue = DispatchQueue(label: "basalt.tcp")
    private let queueKey = DispatchSpecificKey<Void>()
    private var connections: [NWConnection] = []
    private var pendingBytes: [ObjectIdentifier: Int] = [:]
    private var startupContinuation: CheckedContinuation<Void, Error>?
    private let clientCountLock = NSLock()
    private var clientCount = 0

    /// True while at least one preview client is connected. Safe to read
    /// from any thread; producers use it to skip work nobody will receive.
    public var hasClients: Bool {
        clientCountLock.lock()
        defer { clientCountLock.unlock() }
        return clientCount > 0
    }

    private func updateClientCount() {
        clientCountLock.lock()
        clientCount = connections.count
        clientCountLock.unlock()
    }

    public init(port: UInt16, bindHost: String) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw BasaltError("Invalid port \(port)")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(bindHost), port: nwPort)
        listener = try NWListener(using: parameters)
        queue.setSpecific(key: queueKey, value: ())
    }

    /// The port actually bound (differs from init's when passing 0).
    public var port: UInt16? { listener.port?.rawValue }

    /// Starts listening and returns only once Network.framework reports the
    /// listener ready. Bind failures are thrown instead of arriving after
    /// the caller has already announced successful startup.
    public func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startupContinuation = continuation
                self.startOnQueue()
            }
        }
    }

    private func startOnQueue() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.startupContinuation?.resume()
                self.startupContinuation = nil
            case .failed(let error):
                if let continuation = self.startupContinuation {
                    self.startupContinuation = nil
                    continuation.resume(throwing: error)
                } else {
                    self.onFailure?(error)
                }
            case .cancelled:
                if let continuation = self.startupContinuation {
                    self.startupContinuation = nil
                    continuation.resume(throwing: BasaltError("TCP listener was cancelled during startup"))
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                switch state {
                case .ready:
                    print("Client connected: \(connection?.endpoint.debugDescription ?? "?")")
                    self?.onClientConnected?()
                case .failed, .cancelled:
                    if let self, let connection {
                        self.pendingBytes[ObjectIdentifier(connection)] = nil
                        if let index = self.connections.firstIndex(where: { $0 === connection }) {
                            self.connections.remove(at: index)
                            self.updateClientCount()
                            print("Client disconnected")
                        }
                    }
                default:
                    break
                }
            }
            // Handlers run on `queue`, so `connections` is only touched there.
            self.queue.async {
                guard self.connections.count < Self.maxClients else {
                    print("Refusing client: limit of \(Self.maxClients) reached")
                    connection.start(queue: self.queue)
                    connection.cancel()
                    return
                }
                self.connections.append(connection)
                self.updateClientCount()
                connection.start(queue: self.queue)
            }
        }
        listener.start(queue: queue)
    }

    public func broadcast(_ data: Data) {
        queue.async {
            for connection in self.connections where connection.state == .ready {
                let id = ObjectIdentifier(connection)
                let pending = (self.pendingBytes[id] ?? 0) + data.count
                guard pending <= Self.maxPendingBytesPerClient else {
                    print("Dropping client that stopped keeping up (\(pending / 1_000_000) MB queued)")
                    connection.cancel()
                    continue
                }
                self.pendingBytes[id] = pending
                // Completion runs on `queue` (the connection's queue).
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let self, let current = self.pendingBytes[id] {
                        self.pendingBytes[id] = current - data.count
                    }
                    if error != nil { connection.cancel() }
                })
            }
        }
    }

    public func stop() {
        let work = { [self] in
            self.listener.cancel()
            for connection in self.connections { connection.cancel() }
            self.connections.removeAll()
            self.updateClientCount()
            self.pendingBytes.removeAll()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }
}
