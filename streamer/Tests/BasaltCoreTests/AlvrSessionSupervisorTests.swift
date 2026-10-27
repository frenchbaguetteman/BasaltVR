import XCTest
@testable import BasaltCore

/// A session the test ends by hand.
private final class FakeSession: AlvrLiveSession, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var reason: String?
    private var handlers: [@Sendable (String) -> Void] = []
    private(set) var closeCount = 0

    init(_ name: String) { self.name = name }

    func onEnded(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        guard let reason else {
            handlers.append(handler)
            lock.unlock()
            return
        }
        lock.unlock()
        handler(reason)
    }

    func end(_ reason: String) {
        lock.lock()
        guard self.reason == nil else {
            lock.unlock()
            return
        }
        self.reason = reason
        let handlers = self.handlers
        self.handlers.removeAll()
        lock.unlock()
        for handler in handlers { handler(reason) }
    }

    func close() {
        lock.lock()
        closeCount += 1
        lock.unlock()
        end("closed by Basalt")
    }

    var closed: Bool { closes > 0 }

    var closes: Int {
        lock.lock()
        defer { lock.unlock() }
        return closeCount
    }
}

/// Thread-safe recorder for supervisor callbacks.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Hands out scripted connect results in order.
private final class ConnectScript: @unchecked Sendable {
    enum Step {
        case session(FakeSession)
        case failure(Error)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private let fallback: Step
    private(set) var calls = 0

    init(_ steps: [Step], fallback: Step = .failure(BasaltError("no client"))) {
        self.steps = steps
        self.fallback = fallback
    }

    func next() throws -> AlvrLiveSession {
        lock.lock()
        calls += 1
        let step = steps.isEmpty ? fallback : steps.removeFirst()
        lock.unlock()
        switch step {
        case .session(let session): return session
        case .failure(let error): throw error
        }
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}

final class AlvrSessionSupervisorTests: XCTestCase {
    func testSessionEndTearsDownAndReconnectsToTheNextClient() async throws {
        let first = FakeSession("first")
        let second = FakeSession("second")
        let script = ConnectScript([
            .session(first),
            .failure(BasaltError("Quest asleep")),
            .session(second),
        ])
        let supervisor = AlvrSessionSupervisor(
            retryDelayNanoseconds: 10_000_000, reconnectDelayNanoseconds: 10_000_000
        ) { _ in try script.next() }
        let events = Recorder()
        supervisor.onStateChange = { state in events.append("state \(state)") }
        supervisor.onSessionStarted = { session, generation in
            events.append("started \((session as! FakeSession).name) \(generation)")
        }
        supervisor.onSessionEnded = { session, reason in
            // The session is detached before it is closed.
            let session = session as! FakeSession
            events.append("ended \(session.name)\(session.closed ? " (closed)" : ""): \(reason)")
        }
        supervisor.onConnectFailed = { error, attempt in
            events.append("failed \(attempt): \(error.localizedDescription)")
        }

        try await supervisor.startAndWaitForFirstSession()
        XCTAssertEqual(supervisor.state, .streaming(generation: 1))

        first.end("the headset closed the USB stream")
        XCTAssertTrue(waitUntil { supervisor.state == .streaming(generation: 2) })
        XCTAssertTrue(first.closed)
        XCTAssertFalse(second.closed)

        // Stopping takes the same path: detach, then close.
        await supervisor.stopAndWait()
        XCTAssertEqual(first.closes, 1)
        XCTAssertEqual(second.closes, 1)

        let log = events.all
        XCTAssertEqual(log.filter { !$0.hasPrefix("state") }, [
            "started first 1",
            "ended first: the headset closed the USB stream",
            "failed 1: Quest asleep",
            "started second 2",
            "ended second: closed by Basalt",
        ])
        XCTAssertEqual(log.filter { $0.hasPrefix("state") }, [
            "state connecting(attempt: 1)",
            "state streaming(generation: 1)",
            "state waitingToReconnect",
            "state connecting(attempt: 1)",
            "state waitingToReconnect",
            "state connecting(attempt: 2)",
            "state streaming(generation: 2)",
            "state stopped",
        ])
    }

    func testStartupGivesUpAfterTheInitialAttemptLimit() async {
        let script = ConnectScript([])
        let supervisor = AlvrSessionSupervisor(
            initialAttemptLimit: 3, retryDelayNanoseconds: 1_000_000
        ) { _ in try script.next() }
        do {
            try await supervisor.startAndWaitForFirstSession()
            XCTFail("startup should fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "no client")
        }
        XCTAssertEqual(script.callCount, 3)
        XCTAssertEqual(supervisor.state, .stopped)
    }

    func testTrackingTimeoutIsFatalOnlyBeforeTheFirstSession() async throws {
        let startup = ConnectScript([.failure(AlvrTrackingTimeoutError())])
        let failing = AlvrSessionSupervisor(
            initialAttemptLimit: 10, retryDelayNanoseconds: 1_000_000,
            isFatalBeforeFirstSession: { $0 is AlvrTrackingTimeoutError }
        ) { _ in try startup.next() }
        do {
            try await failing.startAndWaitForFirstSession()
            XCTFail("tracking timeout should end startup")
        } catch {
            XCTAssertTrue(error is AlvrTrackingTimeoutError)
        }
        XCTAssertEqual(startup.callCount, 1)

        // After a session has streamed, the same errors and more failures
        // than the startup limit are retried: the Quest may sleep for long.
        let first = FakeSession("first")
        let second = FakeSession("second")
        let script = ConnectScript([.session(first)]
            + Array(repeating: .failure(AlvrTrackingTimeoutError()), count: 5)
            + [.session(second)])
        let supervisor = AlvrSessionSupervisor(
            initialAttemptLimit: 2, retryDelayNanoseconds: 1_000_000,
            reconnectDelayNanoseconds: 1_000_000,
            isFatalBeforeFirstSession: { $0 is AlvrTrackingTimeoutError }
        ) { _ in try script.next() }
        defer { supervisor.stop() }
        try await supervisor.startAndWaitForFirstSession()
        first.end("no ALVR control packets for 5.0 s")
        XCTAssertTrue(waitUntil { supervisor.state == .streaming(generation: 2) })
        XCTAssertEqual(script.callCount, 7)
    }

    func testBeforeReconnectRunsAfterADisconnectAndAfterFailures() async throws {
        let first = FakeSession("first")
        let second = FakeSession("second")
        let script = ConnectScript([
            .session(first), .failure(BasaltError("a")), .failure(BasaltError("b")),
            .session(second),
        ])
        let supervisor = AlvrSessionSupervisor(
            retryDelayNanoseconds: 1_000_000, reconnectDelayNanoseconds: 1_000_000
        ) { _ in try script.next() }
        let calls = Recorder()
        supervisor.beforeReconnect = { failedAttempts in calls.append("\(failedAttempts)") }
        defer { supervisor.stop() }
        try await supervisor.startAndWaitForFirstSession()
        first.end("ALVR closed")
        XCTAssertTrue(waitUntil { supervisor.state == .streaming(generation: 2) })
        XCTAssertEqual(calls.all, ["0", "1", "2"])
    }

    func testStopClosesTheLiveSessionAndDoesNotReconnect() async throws {
        let first = FakeSession("first")
        let script = ConnectScript([.session(first)], fallback: .session(FakeSession("extra")))
        let supervisor = AlvrSessionSupervisor(
            retryDelayNanoseconds: 1_000_000, reconnectDelayNanoseconds: 1_000_000
        ) { _ in try script.next() }
        let ended = Recorder()
        supervisor.onSessionEnded = { session, reason in
            let session = session as! FakeSession
            ended.append("\(session.name) \(session.closed ? "closed" : "open"): \(reason)")
        }
        try await supervisor.startAndWaitForFirstSession()
        // stop() only wakes the loop; it may come from any thread.
        DispatchQueue.global().async { supervisor.stop() }
        XCTAssertTrue(waitUntil { supervisor.state == .stopped })
        await supervisor.stopAndWait()
        // onSessionEnded ran once, before the session was closed once.
        XCTAssertEqual(ended.all, ["first open: closed by Basalt"])
        XCTAssertEqual(first.closes, 1)
        XCTAssertEqual(script.callCount, 1)

        supervisor.stop()
        await supervisor.stopAndWait()
        XCTAssertEqual(ended.all.count, 1)
        XCTAssertEqual(first.closes, 1)
        XCTAssertEqual(script.callCount, 1)
    }

    func testStopDuringAConnectEndsPromptlyAndTearsDownALateSession() async throws {
        let late = FakeSession("late")
        let release = DispatchSemaphore(value: 0)
        let cancelled = Recorder()
        // A handshake blocked in a socket call that ignores cancellation.
        let supervisor = AlvrSessionSupervisor { _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    release.wait()
                    continuation.resume()
                }
            }
            if Task.isCancelled { cancelled.append("cancelled") }
            return late
        }
        let events = Recorder()
        supervisor.onSessionStarted = { session, _ in
            events.append("started \((session as! FakeSession).name)")
        }
        supervisor.onSessionEnded = { session, reason in
            let session = session as! FakeSession
            events.append("ended \(session.name) \(session.closed ? "closed" : "open"): \(reason)")
        }
        supervisor.start()
        XCTAssertTrue(waitUntil { supervisor.state == .connecting(attempt: 1) })

        // The handshake stays blocked, so the wait for it ends at its limit.
        let stopStarted = Date()
        await supervisor.stopAndWait(abandonedConnectTimeoutNanoseconds: 100_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(stopStarted), 1)
        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertTrue(events.all.isEmpty)

        // The abandoned connect was cancelled; the session it still returns
        // never streams and is detached before it is closed.
        release.signal()
        XCTAssertTrue(waitUntil { late.closed })
        XCTAssertEqual(events.all, ["ended late open: closed by Basalt"])
        XCTAssertEqual(late.closes, 1)
        XCTAssertEqual(cancelled.all, ["cancelled"])
    }

    func testStopAndWaitWaitsForAnAbandonedConnectThatReturnsASession() async throws {
        let late = FakeSession("late")
        let release = DispatchSemaphore(value: 0)
        let supervisor = AlvrSessionSupervisor { _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    release.wait()
                    continuation.resume()
                }
            }
            return late
        }
        let ended = Recorder()
        supervisor.onSessionEnded = { session, reason in
            let session = session as! FakeSession
            ended.append("\(session.name) \(session.closed ? "closed" : "open"): \(reason)")
        }
        supervisor.start()
        XCTAssertTrue(waitUntil { supervisor.state == .connecting(attempt: 1) })

        // The handshake finishes while stopAndWait() waits: the session it
        // returns is detached and closed before stopAndWait() returns, so the
        // streamer's teardown never races a late install.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            release.signal()
        }
        await supervisor.stopAndWait()
        XCTAssertEqual(ended.all, ["late open: closed by Basalt"])
        XCTAssertTrue(late.closed)
        XCTAssertEqual(late.closes, 1)
    }

    func testStopDuringTheRetryDelayEndsPromptly() async throws {
        let script = ConnectScript([])
        let supervisor = AlvrSessionSupervisor(
            retryDelayNanoseconds: 30_000_000_000
        ) { _ in try script.next() }
        supervisor.start()
        XCTAssertTrue(waitUntil { supervisor.state == .waitingToReconnect })
        let stopStarted = Date()
        await supervisor.stopAndWait()
        XCTAssertLessThan(Date().timeIntervalSince(stopStarted), 1)
        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertEqual(script.callCount, 1)
    }

    func testStopAndWaitReturnsAtOnceWhenNeverStarted() async {
        let supervisor = AlvrSessionSupervisor { _ in throw BasaltError("unused") }
        await supervisor.stopAndWait()
        XCTAssertEqual(supervisor.state, .idle)
    }

    func testBeaconMailboxDeliversTheNewestAnnouncementAndCloses() async {
        let mailbox = AlvrBeaconMailbox()
        let quest = AlvrBeacon(protocolId: 7, hostname: "Quest")
        mailbox.post(.init(beacon: quest, ip: "10.0.0.2"))
        mailbox.post(.init(beacon: quest, ip: "10.0.0.3"))
        let pending = await mailbox.next()
        XCTAssertEqual(pending?.ip, "10.0.0.3")

        mailbox.post(.init(beacon: quest, ip: "10.0.0.4"))
        mailbox.discardPending()
        async let waited = mailbox.next()
        try? await Task.sleep(nanoseconds: 50_000_000)
        mailbox.post(.init(beacon: quest, ip: "10.0.0.5"))
        let fresh = await waited
        XCTAssertEqual(fresh?.ip, "10.0.0.5")

        async let closed = mailbox.next()
        try? await Task.sleep(nanoseconds: 50_000_000)
        mailbox.close()
        let afterClose = await closed
        XCTAssertNil(afterClose)
        mailbox.post(.init(beacon: quest, ip: "10.0.0.6"))
        let ignored = await mailbox.next()
        XCTAssertNil(ignored)
    }
}

// MARK: - Transport-level detection

final class AlvrDisconnectDetectionTests: XCTestCase {
    func testUSBStreamEOFEndsTheTransportOnceInsteadOfDroppingFramesForever() throws {
        let listener = try LoopbackListener()
        let sender = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: listener.port, localPort: 0, transport: .tcp)
        let peer = try listener.accept()

        let closed = expectation(description: "transport closed")
        closed.expectedFulfillmentCount = 1
        closed.assertForOverFulfill = true
        let reasons = Recorder()
        sender.onTransportClosed = { reason in
            reasons.append(reason)
            closed.fulfill()
        }
        sender.start()
        // ALVR closing (or the Quest pausing it) closes the forwarded socket.
        Darwin.close(peer)
        wait(for: [closed], timeout: 2)
        XCTAssertEqual(reasons.all, ["the headset closed the USB stream"])

        var drops = 0
        sender.onFrameDropped = { drops += 1 }
        XCTAssertFalse(sender.send(annexB: Data([0, 0, 0, 1, 0x65]),
                                   timestampNanoseconds: 1, isIDR: true))
        XCTAssertEqual(drops, 1)
        sender.close()
    }

    func testBrokenPipeOnVideoWriteEndsTheTransport() throws {
        let listener = try LoopbackListener()
        let sender = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: listener.port, localPort: 0, transport: .tcp)
        let peer = try listener.accept()
        let closed = expectation(description: "transport closed after a failed write")
        sender.onTransportClosed = { _ in closed.fulfill() }
        sender.start()
        // RST instead of FIN: the next write fails like the reported
        // "Broken pipe" after the Quest dropped the session.
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(peer, SOL_SOCKET, SO_LINGER, &linger,
                   socklen_t(MemoryLayout<Darwin.linger>.size))
        Darwin.close(peer)
        usleep(50_000)
        for timestamp in 1...3 {
            sender.send(annexB: Data(repeating: 0x41, count: 64 * 1_024),
                        timestampNanoseconds: UInt64(timestamp), isIDR: false)
            usleep(20_000)
        }
        wait(for: [closed], timeout: 2)
        sender.close()
    }

    func testClosingAWiFiSenderReleasesTheUDPPortForTheNextSession() throws {
        let probe = socket(AF_INET, SOCK_DGRAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var bound = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &size) }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        Darwin.close(probe)

        let first = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: 9, localPort: port, transport: .udp)
        XCTAssertThrowsError(try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: 9, localPort: port, transport: .udp))
        first.close()
        first.close()
        let second = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: 9, localPort: port, transport: .udp)
        second.close()
        withExtendedLifetime(first) {}
    }

    func testSilentControlConnectionEndsTheSessionAfterTheReceiveTimeout() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { Darwin.close(sockets[1]) }
        let session = AlvrSessionHandshakeResult(
            clientState: .standby, negotiatedSettings: nil, streamReady: true,
            socket: sockets[0], receiveTimeoutNanoseconds: 1_200_000_000)
        let disconnected = expectation(description: "silent client dropped")
        let reasons = Recorder()
        session.onDisconnect { reason in
            reasons.append(reason)
            disconnected.fulfill()
        }
        // Client keepalives hold the session open past the timeout...
        let keepAlive = Data([0, 0, 0, 4, 2, 0, 0, 0])
        for _ in 0..<8 {
            _ = keepAlive.withUnsafeBytes { Darwin.send(sockets[1], $0.baseAddress, keepAlive.count, 0) }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(reasons.all.isEmpty)
        // ...and silence (Wi-Fi out of range, no TCP reset) ends it.
        await fulfillment(of: [disconnected], timeout: 3)
        XCTAssertTrue(reasons.all.first?.hasPrefix("no ALVR control packets") == true,
                      "\(reasons.all)")
        withExtendedLifetime(session) {}
    }
}

// MARK: - End to end against a fake ALVR client

/// A loopback stand-in for the Quest's ALVR v20 client in wired mode: it
/// listens on a control and a stream port (what `adb forward` exposes),
/// answers the handshake, sends keepalives and tracking, and records what
/// the streamer sends. After a session ends it waits for the next one, like
/// the real client's connection loop.
private final class FakeAlvrClient: @unchecked Sendable {
    let controlPort: UInt16
    let streamPort: UInt16
    private let controlListener: LoopbackListener
    private let streamListener: LoopbackListener
    private let lock = NSLock()
    private var running = true
    private var currentControl: Int32 = -1
    private var currentStream: Int32 = -1
    private var sessions = 0
    private var serverKeepAlives = 0
    private var decoderConfigs = 0
    private var lastDecoderConfig: Data?
    private var lastStreamConfig: Data?
    private var videoPackets: [Int: Int] = [:]

    init() throws {
        controlListener = try LoopbackListener()
        streamListener = try LoopbackListener()
        controlPort = controlListener.port
        streamPort = streamListener.port
        Thread.detachNewThread { [self] in serve() }
    }

    var sessionCount: Int { locked { sessions } }
    var keepAlivesReceived: Int { locked { serverKeepAlives } }
    var decoderConfigsReceived: Int { locked { decoderConfigs } }
    /// The newest `DecoderConfig` and `StreamConfig` payloads (unframed).
    var latestDecoderConfig: Data? { locked { lastDecoderConfig } }
    var latestStreamConfig: Data? { locked { lastStreamConfig } }
    func videoPacketsReceived(session: Int) -> Int { locked { videoPackets[session] ?? 0 } }

    /// The Quest slept or ALVR closed: both sockets go away.
    func dropSession() {
        let (control, stream) = locked { (currentControl, currentStream) }
        Darwin.shutdown(stream, SHUT_RDWR)
        Darwin.shutdown(control, SHUT_RDWR)
    }

    /// Only the stream socket dies; the next video write breaks.
    func dropStreamOnly() {
        let stream = locked { currentStream }
        Darwin.shutdown(stream, SHUT_RDWR)
    }

    func stop() {
        locked { running = false }
        dropSession()
        controlListener.close()
        streamListener.close()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var isRunning: Bool { locked { running } }

    private func serve() {
        while isRunning {
            guard let control = try? controlListener.accept() else { return }
            handleSession(control: control)
        }
    }

    private func handleSession(control: Int32) {
        defer { Darwin.close(control) }
        var accepted = AlvrWire.acceptedPrefix(protocolId: 42, name: "Fake Quest")
        accepted.append(1)
        accepted.append(AlvrWire.littleEndian(UInt32(1680)))
        accepted.append(AlvrWire.littleEndian(UInt32(1760)))
        accepted.append(AlvrWire.littleEndian(UInt64(1)))
        accepted.append(AlvrWire.littleEndian(Float(72).bitPattern))
        accepted.append(AlvrWire.littleEndian(UInt32(48_000)))
        guard AlvrWire.sendAll(AlvrWire.framed(accepted), to: control),
              let streamConfig = AlvrWire.receiveFrame(fd: control), // StreamConfig
              locked({ lastStreamConfig = streamConfig; return true }),
              AlvrWire.receiveFrame(fd: control) == Data([0, 0, 0, 0]), // StartStream
              AlvrWire.sendAll(AlvrWire.framed(Data([3, 0, 0, 0])), to: control), // StreamReady
              let stream = try? streamListener.accept() else { return }
        defer { Darwin.close(stream) }

        let session = locked { () -> Int in
            sessions += 1
            currentControl = control
            currentStream = stream
            return sessions
        }
        let done = DispatchGroup()
        let alive = ManagedFlag()

        done.enter()
        Thread.detachNewThread { [self] in   // control reader
            defer { alive.clear(); done.leave() }
            while let packet = AlvrWire.receiveFrame(fd: control) {
                if packet == Data([3, 0, 0, 0]) {
                    locked { serverKeepAlives += 1 }
                } else if packet.first == 1 {
                    locked {
                        decoderConfigs += 1
                        lastDecoderConfig = packet
                    }
                }
            }
        }
        done.enter()
        Thread.detachNewThread { [self] in   // stream reader
            defer { alive.clear(); done.leave() }
            while let packet = AlvrWire.receiveFrame(fd: stream) {
                if packet.count >= 2, packet[packet.startIndex + 1] == 3 {
                    locked { videoPackets[session, default: 0] += 1 }
                }
            }
        }
        // Client keepalives (500 ms in ALVR) and tracking at ~100 Hz.
        var tick = 0
        while alive.isSet {
            tick += 1
            let timestamp = UInt64(session) * 1_000_000_000_000 + UInt64(tick) * 10_000_000
            var duration = AlvrWire.littleEndian(timestamp / 1_000_000_000)
            duration.append(AlvrWire.littleEndian(UInt32(timestamp % 1_000_000_000)))
            if !AlvrWire.sendAll(AlvrWire.uplink(streamID: 0, payload: duration), to: stream) {
                break
            }
            if tick.isMultiple(of: 20),
               !AlvrWire.sendAll(AlvrWire.framed(Data([2, 0, 0, 0])), to: control) {
                break
            }
            usleep(10_000)
        }
        Darwin.shutdown(stream, SHUT_RDWR)
        Darwin.shutdown(control, SHUT_RDWR)
        done.wait()
    }
}

private final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func clear() { lock.lock(); value = false; lock.unlock() }
}

final class AlvrReconnectEndToEndTests: XCTestCase {
    private static let parameterSetsIDR = Data([
        0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1f,   // SPS
        0, 0, 0, 1, 0x68, 0xee, 0x3c, 0x80,   // PPS
        0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00,   // IDR slice
    ])

    private struct Harness {
        let client: FakeAlvrClient
        let supervisor: AlvrSessionSupervisor
        let router: AlvrVideoStreamRouter
        let events: Recorder
    }

    private func makeHarness(codec: VideoCodec = .h264) throws -> Harness {
        let client = try FakeAlvrClient()
        let router = AlvrVideoStreamRouter(codec: codec)
        let events = Recorder()
        let request = AlvrClientSessionRequest(
            host: "127.0.0.1", controlPort: client.controlPort,
            streamPort: client.streamPort, localStreamPort: 0, wired: true,
            requestedViewWidth: 1152, requestedViewHeight: 1216,
            preferredRefreshRate: 72, latencyPreset: .low,
            controllerPrediction: .full, codec: codec,
            trackingTimeoutNanoseconds: 2_000_000_000)
        let supervisor = AlvrSessionSupervisor(
            initialAttemptLimit: 10, retryDelayNanoseconds: 100_000_000,
            reconnectDelayNanoseconds: 50_000_000
        ) { _ in
            try await AlvrClientSession.connect(request) { _, stream in
                stream.onFrameDropped = { events.append("network drop") }
            }
        }
        supervisor.onSessionStarted = { session, generation in
            let session = session as! AlvrClientSession
            router.install(session.stream, controlSession: session.control)
            events.append("started \(generation)")
        }
        supervisor.onSessionEnded = { session, reason in
            router.uninstall((session as! AlvrClientSession).stream)
            events.append("input reset")       // what the streamer sends the runtime
            events.append("ended: \(reason)")
        }
        return Harness(client: client, supervisor: supervisor, router: router, events: events)
    }

    /// The reported failure: StreamReady, then no game frames for a long
    /// time (OpenComposite's probe session, the game loading), then the
    /// client drops the session. The streamer must give the idle client a
    /// decoder configuration and a picture, notice the drop without a video
    /// write, and accept the client's reconnect with a fresh IDR and decoder
    /// configuration.
    func testClientDropsWhileTheRuntimeIsIdleThenReconnects() async throws {
        let harness = try makeHarness()
        let client = harness.client
        let router = harness.router
        defer {
            harness.supervisor.stop()
            client.stop()
        }
        try await harness.supervisor.startAndWaitForFirstSession()
        XCTAssertTrue(router.hasStream)

        // Runtime idle, no game frame yet: the filler sends black until one
        // black IDR is delivered, then stays quiet. ALVR keeps showing that
        // picture; only control keepalives keep the session alive.
        let gate = VideoLossRecoveryGate()
        let filler = RuntimeIdleVideoFiller<Int>(
            idleThresholdNanoseconds: 100_000_000, intervalNanoseconds: 100_000_000)
        let fillerTask = Task.detached {
            while !Task.isCancelled {
                if let frame = filler.nextFrame(
                    latestTrackingTimestamp: router.timestampForVideoFrame(),
                    hasStream: router.hasStream,
                    referenceChainBroken: gate.isAwaitingIDR) {
                    XCTAssertFalse(frame.isRepeat, "no game frame exists yet")
                    if gate.prepareEncode(transportBusy: false) == .encodeKeyframe,
                       gate.admit(isIDR: true),
                       router.send(annexB: Self.parameterSetsIDR, isIDR: true,
                                   timestampNanoseconds: frame.trackingTimestampNanoseconds) {
                        gate.idrDelivered()
                        filler.recordDelivered(
                            presentationNanoseconds: frame.presentationNanoseconds)
                    }
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer { fillerTask.cancel() }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertGreaterThanOrEqual(client.keepAlivesReceived, 2,
                                    "ALVR drops a server that is silent for 2 s")
        XCTAssertEqual(client.videoPacketsReceived(session: 1), 1,
                       "one delivered black IDR is enough; ALVR keeps the last picture")
        XCTAssertGreaterThanOrEqual(client.decoderConfigsReceived, 1)
        XCTAssertTrue(router.hasStream)

        // The Quest sleeps / ALVR closes: no video write is needed to notice.
        fillerTask.cancel()
        client.dropSession()
        XCTAssertTrue(waitUntil { harness.events.all.contains { $0.hasPrefix("ended:") } })
        XCTAssertFalse(router.hasStream)
        XCTAssertTrue(harness.events.all.contains("input reset"))
        // Game frames arriving now go nowhere instead of counting as
        // network drops forever.
        router.send(annexB: Self.parameterSetsIDR, isIDR: true, timestampNanoseconds: 1)
        XCTAssertFalse(harness.events.all.contains("network drop"))

        // ALVR's connection loop comes back: the streamer reconnects.
        XCTAssertTrue(waitUntil(timeout: 5) { harness.events.all.contains("started 2") })
        XCTAssertEqual(client.sessionCount, 2)
        XCTAssertTrue(router.hasStream)
        let configsBefore = client.decoderConfigsReceived
        let timestamp = try XCTUnwrap(router.timestampForVideoFrame())
        router.send(annexB: Self.parameterSetsIDR, isIDR: true, timestampNanoseconds: timestamp)
        XCTAssertTrue(waitUntil { client.videoPacketsReceived(session: 2) >= 1 })
        XCTAssertTrue(waitUntil { client.decoderConfigsReceived > configsBefore })
    }

    /// The log's exact symptom: only the USB stream breaks, so the next
    /// video write fails with Broken pipe. That ends the session and the
    /// streamer reconnects instead of dropping every frame afterwards.
    func testBrokenUSBStreamEndsTheSessionAndReconnects() async throws {
        let harness = try makeHarness()
        let client = harness.client
        let router = harness.router
        defer {
            harness.supervisor.stop()
            client.stop()
        }
        try await harness.supervisor.startAndWaitForFirstSession()
        client.dropStreamOnly()
        for _ in 0..<20 where router.hasStream {
            if let timestamp = router.timestampForVideoFrame() {
                router.send(annexB: Self.parameterSetsIDR, isIDR: true,
                            timestampNanoseconds: timestamp)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(waitUntil { harness.events.all.contains { $0.hasPrefix("ended:") } })
        XCTAssertTrue(waitUntil(timeout: 5) { harness.events.all.contains("started 2") })
        XCTAssertLessThanOrEqual(
            harness.events.all.filter { $0 == "network drop" }.count, 1)
        let timestamp = try XCTUnwrap(router.timestampForVideoFrame())
        router.send(annexB: Self.parameterSetsIDR, isIDR: true, timestampNanoseconds: timestamp)
        XCTAssertTrue(waitUntil { client.videoPacketsReceived(session: 2) >= 1 })
    }

    /// An HEVC session: the StreamConfig names the codec, and an IDR sends
    /// ALVR's DecoderConfig with CodecType::Hevc and the VPS+SPS+PPS buffer.
    func testHEVCSessionSendsHEVCStreamConfigAndDecoderConfig() async throws {
        let harness = try makeHarness(codec: .hevc)
        let client = harness.client
        let router = harness.router
        defer {
            harness.supervisor.stop()
            client.stop()
        }
        try await harness.supervisor.startAndWaitForFirstSession()

        let streamConfig = try XCTUnwrap(client.latestStreamConfig)
        let sessionLength = Int(streamConfig.prefix(8).enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        })
        let session = try XCTUnwrap(JSONSerialization.jsonObject(
            with: streamConfig[8..<(8 + sessionLength)]) as? [String: Any])
        let video = try XCTUnwrap(
            (session["session_settings"] as? [String: Any])?["video"] as? [String: Any])
        XCTAssertEqual(video["preferred_codec"] as? [String: String], ["variant": "Hevc"])

        let parameterSets = Data([
            0, 0, 0, 1, 0x40, 0x01, 0x0c, 0x01,   // VPS
            0, 0, 0, 1, 0x42, 0x01, 0x01, 0x01,   // SPS
            0, 0, 0, 1, 0x44, 0x01, 0xc0, 0x72,   // PPS
        ])
        let accessUnit = parameterSets + Data([0, 0, 0, 1, 0x28, 0x01, 0xaf, 0x2d]) // IDR_N_LP
        let timestamp = try XCTUnwrap(router.timestampForVideoFrame())
        router.send(annexB: accessUnit, isIDR: true, timestampNanoseconds: timestamp)
        XCTAssertTrue(waitUntil { client.latestDecoderConfig != nil })
        var expected = Data([1, 0, 0, 0, 1, 0, 0, 0])  // DecoderConfig, CodecType::Hevc
        expected.append(contentsOf: [UInt8(parameterSets.count), 0, 0, 0, 0, 0, 0, 0])
        expected.append(parameterSets)
        XCTAssertEqual(client.latestDecoderConfig, expected)
        XCTAssertTrue(waitUntil { client.videoPacketsReceived(session: 1) >= 1 })
    }
}

// MARK: - Loopback helpers

private final class LoopbackListener: @unchecked Sendable {
    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BasaltError("socket failed") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { throw BasaltError("bind/listen failed") }
        var actual = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        self.fd = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    func accept() throws -> Int32 {
        let peer = Darwin.accept(fd, nil, nil)
        guard peer >= 0 else { throw BasaltError("accept failed") }
        var noSigPipe: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return peer
    }

    func close() {
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

private enum AlvrWire {
    static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func acceptedPrefix(protocolId: UInt64, name: String) -> Data {
        let nameData = Data(name.utf8)
        var packet = littleEndian(UInt32(0))
        packet.append(littleEndian(protocolId))
        packet.append(littleEndian(UInt64(nameData.count)))
        packet.append(nameData)
        packet.append(littleEndian(UInt32(0)))
        packet.append(contentsOf: [127, 0, 0, 1])
        return packet
    }

    static func framed(_ payload: Data) -> Data {
        var result = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }

    /// One ALVR stream packet; its 4-byte length prefix doubles as the
    /// wired TCP framing.
    static func uplink(streamID: UInt16, payload: Data) -> Data {
        var result = Data(repeating: 0, count: 18)
        result.append(payload)
        func write<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.bigEndian) {
                result.replaceSubrange(offset..<offset + $0.count, with: $0)
            }
        }
        write(UInt32(result.count - 4), at: 0)
        write(streamID, at: 4)
        write(UInt32(1), at: 10)
        return result
    }

    static func sendAll(_ data: Data, to fd: Int32) -> Bool {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { return false }
            offset += sent
        }
        return true
    }

    static func receiveExactly(_ count: Int, fd: Int32) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else { return nil }
            offset += received
        }
        return data
    }

    static func receiveFrame(fd: Int32) -> Data? {
        guard let prefix = receiveExactly(4, fd: fd) else { return nil }
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 8 * 1_024 * 1_024 else { return nil }
        return receiveExactly(length, fd: fd)
    }
}
