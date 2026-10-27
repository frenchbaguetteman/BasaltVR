import Foundation
import XCTest
@testable import BasaltCore

/// Live loopback tests for runtime connection replacement. The Lab launches
/// Robot Repair (vr.exe) with CreateProcess(bInheritHandles=TRUE) and exits;
/// the child keeps The Lab's control socket open, so the old connection never
/// sees EOF. The new game's authenticated Hello must replace it, or the new
/// session runs headless and the headset stays black.
final class RuntimeLinkReplacementTests: XCTestCase {
    private var link: RuntimeLink!
    private var controlPath = ""
    private var events: EventLog!

    override func setUp() async throws {
        controlPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("basalt-replace-\(UUID().uuidString).control").path
        link = try RuntimeLink(controlFilePath: controlPath)
        let events = EventLog()
        self.events = events
        link.onHello = { sessionId, _ in events.append("hello \(sessionId)") }
        link.onTeardown = { events.append("teardown") }
        link.onReplaced = { events.append("replaced") }
        link.onProtocolError = { events.append("refused: \($0)") }
        try await link.start()
    }

    override func tearDown() {
        link.stop()
        link = nil
    }

    func testAuthenticatedHelloReplacesAStaleLiveConnection() throws {
        let (port, token) = try readControlFile()

        let stale = try LoopbackClient(port: port)
        try stale.sendHello(token: token, session: 1)
        XCTAssertEqual(try stale.receiveMessageType(), RuntimeLink.MessageType.helloAck.rawValue)

        // The stale connection stays open, exactly like the inherited socket.
        let fresh = try LoopbackClient(port: port)
        try fresh.sendHello(token: token, session: 2)
        XCTAssertEqual(try fresh.receiveMessageType(), RuntimeLink.MessageType.helloAck.rawValue,
                       "the new game's session must not be left headless")
        XCTAssertTrue(stale.waitForClose(), "the superseded connection must be closed")
        XCTAssertTrue(events.waitFor("hello 2"))
        XCTAssertEqual(events.snapshot(), ["hello 1", "replaced", "teardown", "hello 2"])
    }

    func testUnauthenticatedConnectionCannotReplaceTheLiveSession() throws {
        let (port, token) = try readControlFile()

        let live = try LoopbackClient(port: port)
        try live.sendHello(token: token, session: 7)
        XCTAssertEqual(try live.receiveMessageType(), RuntimeLink.MessageType.helloAck.rawValue)

        let intruder = try LoopbackClient(port: port)
        try intruder.sendHello(token: String(repeating: "0", count: RuntimeLink.tokenLength),
                               session: 8)
        XCTAssertTrue(intruder.waitForClose(), "a wrong token must be dropped")

        let junk = try LoopbackClient(port: port)
        try junk.send(Data([0xff, 0xff, 0xff, 0xff, 0x01, 0x00]))
        XCTAssertTrue(junk.waitForClose(), "a malformed first message must be dropped")

        XCTAssertFalse(live.waitForClose(timeout: 0.3), "the live session must survive")
        XCTAssertEqual(events.snapshot(), ["hello 7"])
    }

    private func readControlFile() throws -> (UInt16, String) {
        let line = try String(contentsOfFile: controlPath, encoding: .utf8)
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\n" })
        let port = try XCTUnwrap(UInt16(try XCTUnwrap(fields.first)))
        return (port, String(fields[1]))
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func waitFor(_ event: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if snapshot().contains(event) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }
}

/// A blocking BSD-socket client that speaks just enough of the control protocol.
private final class LoopbackClient {
    private let socketDescriptor: Int32

    init(port: UInt16) throws {
        socketDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketDescriptor >= 0 else { throw BasaltError("socket failed") }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(socketDescriptor)
            throw BasaltError("connect failed")
        }
    }

    deinit { close(socketDescriptor) }

    func send(_ data: Data) throws {
        let written = data.withUnsafeBytes {
            Darwin.send(socketDescriptor, $0.baseAddress, data.count, 0)
        }
        guard written == data.count else { throw BasaltError("send failed") }
    }

    func sendHello(token: String, session: UInt64) throws {
        let renderer = Data("Apple M3 Pro".utf8)
        var payload = Data()
        payload.appendLE(RuntimeLink.protocolVersion)
        payload.append(Data(token.utf8))
        payload.appendLE(session)
        payload.appendLE(UInt16(renderer.count))
        payload.append(renderer)
        var message = Data()
        message.appendLE(UInt32(2 + payload.count))
        message.appendLE(RuntimeLink.MessageType.hello.rawValue)
        message.append(payload)
        try send(message)
    }

    /// Reads one length-framed message and returns its type.
    func receiveMessageType() throws -> UInt16 {
        let header = try receiveExactly(6)
        let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
            | Int(header[3]) << 24
        _ = try receiveExactly(length - 2)
        return UInt16(header[4]) | UInt16(header[5]) << 8
    }

    /// True once the peer closes (EOF or reset); skips any pending messages.
    func waitForClose(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptor = pollfd(fd: socketDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&descriptor, 1, remaining) > 0 else { continue }
            let count = recv(socketDescriptor, &buffer, buffer.count, 0)
            if count <= 0 { return true }
        }
        return false
    }

    private func receiveExactly(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let result = bytes.withUnsafeMutableBytes {
                recv(socketDescriptor, $0.baseAddress! + received, count - received, 0)
            }
            guard result > 0 else { throw BasaltError("connection closed before a message") }
            received += result
        }
        return bytes
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
