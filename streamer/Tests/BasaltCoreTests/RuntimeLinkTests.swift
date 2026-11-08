import XCTest
@testable import BasaltCore

final class RuntimeLinkTests: XCTestCase {
    func testControlFileCarriesOptionalRecommendedViewSize() {
        let token = String(repeating: "a", count: 32)
        XCTAssertEqual(
            RuntimeLink.controlFileLine(
                port: 4321, token: token, recommendedViewSize: .balanced),
            "4321 \(token) 1152 1216\n")
        XCTAssertEqual(
            RuntimeLink.controlFileLine(
                port: 4321, token: token, recommendedViewSize: nil),
            "4321 \(token)\n")
    }

    func testRejectsViewSizesTheRuntimeWouldIgnore() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("basalt-\(UUID().uuidString).control").path
        XCTAssertNoThrow(try RuntimeLink(
            controlFilePath: path,
            recommendedViewSize: try PerEyeResolution(
                width: RuntimeLink.maximumViewWidth, height: RuntimeLink.maximumViewHeight)))
        XCTAssertThrowsError(try RuntimeLink(
            controlFilePath: path,
            recommendedViewSize: try PerEyeResolution(width: 1_920, height: 1_920)))
    }

    /// RuntimeLink mirrors basalt_control_protocol.h by hand. A drifted
    /// version or message id connects headlessly (black headset), so pin the
    /// mirror to the header the PE runtime is built from.
    func testWireConstantsMatchRuntimeProtocolHeader() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let header = try String(
            contentsOf: repository.appendingPathComponent(
                "runtime/pe/basalt_control_protocol.h"),
            encoding: .utf8)

        func values(_ pattern: String) throws -> [String: Int] {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(header.startIndex..., in: header)
            var result: [String: Int] = [:]
            for match in regex.matches(in: header, range: range) {
                guard let name = Range(match.range(at: 1), in: header),
                      let value = Range(match.range(at: 2), in: header) else { continue }
                result[String(header[name])] = Int(header[value])
            }
            return result
        }

        let defines = try values(#"#define BASALT_CONTROL_([A-Z_]+) ([0-9]+)u"#)
        XCTAssertEqual(defines["PROTOCOL_VERSION"], Int(RuntimeLink.protocolVersion))
        XCTAssertEqual(defines["TOKEN_LENGTH"], RuntimeLink.tokenLength)
        XCTAssertEqual(defines["MAX_MESSAGE_LENGTH"], RuntimeLink.maxMessageLength)
        XCTAssertEqual(defines["MIN_VIEW_DIMENSION"], PerEyeResolution.dimensionRange.lowerBound)
        XCTAssertEqual(defines["MAX_VIEW_WIDTH"], RuntimeLink.maximumViewWidth)
        XCTAssertEqual(defines["MAX_VIEW_HEIGHT"], RuntimeLink.maximumViewHeight)
        XCTAssertEqual(defines["MIN_DISPLAY_PERIOD_NS"],
                       Int(RuntimeLink.minimumDisplayPeriodNanoseconds))
        XCTAssertEqual(defines["MAX_DISPLAY_PERIOD_NS"],
                       Int(RuntimeLink.maximumDisplayPeriodNanoseconds))
        XCTAssertEqual(defines["DEFAULT_DISPLAY_PERIOD_NS"],
                       Int(RuntimeLink.defaultDisplayPeriodNanoseconds))
        XCTAssertEqual(defines["HAND_JOINT_COUNT"], RuntimeLink.handJointCount)
        XCTAssertEqual(defines["HAND_SKELETON_PAYLOAD_LENGTH"],
                       RuntimeLink.handSkeletonPayloadLength)
        XCTAssertTrue(header.contains(
            "#define BASALT_CONTROL_FEATURE_HAND_TRACKING \"\(RuntimeLink.handTrackingFeature)\""))

        // BASALT_MSG_HELLO_ACK = 2 must mirror `case helloAck = 2`.
        let headerMessages = try values(#"BASALT_MSG_([A-Z_]+) = ([0-9]+),"#)
        let swiftMessages = Dictionary(uniqueKeysWithValues:
            RuntimeLink.MessageType.allCases.map {
                (String(describing: $0), Int($0.rawValue))
            })
        let camelCasedHeader = Dictionary(uniqueKeysWithValues:
            headerMessages.map { name, value in
                let words = name.lowercased().split(separator: "_")
                let camel = words.enumerated().map { index, word in
                    index == 0 ? String(word) : word.capitalized
                }.joined()
                return (camel, value)
            })
        XCTAssertFalse(camelCasedHeader.isEmpty)
        XCTAssertEqual(swiftMessages, camelCasedHeader)
    }

    func testOnlyCoreVideoCompatibleBGRAIsStreamable() {
        let bgraFourCC: UInt32 = 0x4247_5241
        let rgbaFourCC: UInt32 = 0x5247_4241
        XCTAssertTrue(RuntimeLink.isStreamableSwapchainFormat(
            dxgiFormat: 87, iosurfacePixelFormat: bgraFourCC))
        XCTAssertTrue(RuntimeLink.isStreamableSwapchainFormat(
            dxgiFormat: 91, iosurfacePixelFormat: bgraFourCC))
        XCTAssertFalse(RuntimeLink.isStreamableSwapchainFormat(
            dxgiFormat: 28, iosurfacePixelFormat: rgbaFourCC))
        XCTAssertFalse(RuntimeLink.isStreamableSwapchainFormat(
            dxgiFormat: 28, iosurfacePixelFormat: bgraFourCC))
        XCTAssertFalse(RuntimeLink.isStreamableSwapchainFormat(
            dxgiFormat: 87, iosurfacePixelFormat: rgbaFourCC))
    }

    func testHelloAckCarriesTheHeadsetDisplayPeriod() {
        XCTAssertEqual(RuntimeLink.displayPeriodNanoseconds(refreshRate: 72),
                       RuntimeLink.defaultDisplayPeriodNanoseconds)
        XCTAssertEqual(RuntimeLink.displayPeriodNanoseconds(refreshRate: 90), 11_111_111)
        XCTAssertEqual(RuntimeLink.displayPeriodNanoseconds(refreshRate: 120), 8_333_333)
        XCTAssertEqual(RuntimeLink.displayPeriodNanoseconds(refreshRate: 240), 4_166_667)
        for invalid: Float in [0, -72, 20, 241, .nan, .infinity] {
            XCTAssertNil(RuntimeLink.displayPeriodNanoseconds(refreshRate: invalid), "\(invalid)")
        }

        let ack = RuntimeLink.helloAckPayload(displayPeriodNanoseconds: 11_111_111)
        var expected = Data()
        expected.appendTestU16(RuntimeLink.protocolVersion)
        expected.appendTestU64(11_111_111)
        XCTAssertEqual(ack, expected)
    }

    func testFrameReadyHeaderPreservesExactQuestTrackingTimestamp() throws {
        var payload = Data()
        payload.appendTestU64(42)
        payload.appendTestU64(UInt64(bitPattern: Int64(-123)))
        payload.appendTestU64(9_876_543_210)
        payload.appendTestU32(2)
        payload.append(Data(repeating: 0, count: 2 * 76))

        let header = try XCTUnwrap(RuntimeLink.frameReadyHeader(from: payload))
        XCTAssertEqual(header.frameNumber, 42)
        XCTAssertEqual(header.displayTime, -123)
        XCTAssertEqual(header.questTrackingTimestampNanoseconds, 9_876_543_210)
        XCTAssertEqual(header.viewCount, 2)
    }

    func testFrameReadyHeaderRejectsLegacyAndMismatchedLayouts() {
        XCTAssertNil(RuntimeLink.frameReadyHeader(from: Data(repeating: 0, count: 20 + 76)))

        var payload = Data(repeating: 0, count: 28 + 76)
        payload.replaceSubrange(24..<28, with: [2, 0, 0, 0])
        XCTAssertNil(RuntimeLink.frameReadyHeader(from: payload))
    }

    func testAsynchronousFrameCompletionsAreAcknowledgedInOrder() {
        var completed: Set<UInt64> = [2]
        var lastAcknowledged: UInt64 = 0
        XCTAssertEqual(RuntimeLink.orderedAcknowledgements(
            completed: &completed, lastAcknowledged: &lastAcknowledged), [])

        completed.insert(1)
        XCTAssertEqual(RuntimeLink.orderedAcknowledgements(
            completed: &completed, lastAcknowledged: &lastAcknowledged), [1, 2])
        XCTAssertEqual(lastAcknowledged, 2)
        XCTAssertTrue(completed.isEmpty)

        completed.formUnion([4, 3])
        XCTAssertEqual(RuntimeLink.orderedAcknowledgements(
            completed: &completed, lastAcknowledged: &lastAcknowledged), [3, 4])
        XCTAssertEqual(lastAcknowledged, 4)
    }

    func testHeadPosePayloadPreservesTimestampAndNormalizesQuaternion() throws {
        let pose = AlvrHeadPose(
            orientationX: 0, orientationY: 1, orientationZ: 0, orientationW: 1,
            positionX: 0.25, positionY: 1.5, positionZ: -0.5)
        let payload = try XCTUnwrap(RuntimeLink.headPosePayload(
            timestampNanoseconds: 123_456_789, pose: pose))

        XCTAssertEqual(payload.count, 36)
        XCTAssertEqual(payload.readTestU64(at: 0), 123_456_789)
        XCTAssertEqual(payload.readTestF32(at: 8), 0, accuracy: 0.000_001)
        XCTAssertEqual(payload.readTestF32(at: 12), 0.707_106_77, accuracy: 0.000_001)
        XCTAssertEqual(payload.readTestF32(at: 20), 0.707_106_77, accuracy: 0.000_001)
        XCTAssertEqual(payload.readTestF32(at: 24), 0.25)
        XCTAssertEqual(payload.readTestF32(at: 28), 1.5)
        XCTAssertEqual(payload.readTestF32(at: 32), -0.5)
    }

    func testHeadPosePayloadRejectsInvalidValues() {
        let pose = AlvrHeadPose(
            orientationX: 0, orientationY: 0, orientationZ: 0, orientationW: 1,
            positionX: .nan, positionY: 0, positionZ: 0)
        XCTAssertNil(RuntimeLink.headPosePayload(timestampNanoseconds: 1, pose: pose))
    }

    func testControllerButtonAndProfilePayloads() throws {
        let pose = AlvrHeadPose(
            orientationX: 0, orientationY: 0, orientationZ: 0, orientationW: 1.5,
            positionX: -0.2, positionY: 1.2, positionZ: -0.4)
        let motion = AlvrControllerMotion(
            pose: pose, linearVelocityX: 1, linearVelocityY: 2,
            linearVelocityZ: 3, angularVelocityX: 4,
            angularVelocityY: 5, angularVelocityZ: 6)
        let controller = try XCTUnwrap(RuntimeLink.controllerMotionPayload(
            timestampNanoseconds: 99, hand: .left, motion: motion))
        XCTAssertEqual(controller.count, 68)
        XCTAssertEqual(controller.readTestU64(at: 0), 99)
        XCTAssertEqual(controller.readTestU32(at: 8), 0)
        XCTAssertEqual(controller.readTestF32(at: 32), -0.2)
        XCTAssertEqual(controller.readTestF32(at: 64), 6)

        let mask = try XCTUnwrap(RuntimeLink.controllerMaskPayload(
            timestampNanoseconds: 100, activeMask: 2))
        XCTAssertEqual(mask.count, 16)
        XCTAssertEqual(mask.readTestU64(at: 0), 100)
        XCTAssertEqual(mask.readTestU32(at: 8), 2)
        XCTAssertEqual(mask.readTestU32(at: 12), 0)
        XCTAssertNil(RuntimeLink.controllerMaskPayload(
            timestampNanoseconds: 100, activeMask: 4))

        let button = try XCTUnwrap(RuntimeLink.buttonStatePayload(
            AlvrButtonEntry(pathID: 0x1234, value: .scalar(0.75))))
        XCTAssertEqual(button.count, 16)
        XCTAssertEqual(button.readTestU64(at: 0), 0x1234)
        XCTAssertEqual(button.readTestU32(at: 8), 1)
        XCTAssertEqual(button.readTestF32(at: 12), 0.75)
        // The runtime treats path 0 as a corrupt connection.
        XCTAssertNil(RuntimeLink.buttonStatePayload(
            AlvrButtonEntry(pathID: 0, value: .binary(true))))

        let profile = RuntimeLink.interactionProfilePayload(
            hand: .right, profileID: 0x0812_fd85_c843_84a6)
        XCTAssertEqual(profile.count, 12)
        XCTAssertEqual(profile.readTestU32(at: 0), 1)
        XCTAssertEqual(profile.readTestU64(at: 4), 0x0812_fd85_c843_84a6)
    }

    func testViewConfigPayloadPreservesCalibratedEyeOrder() throws {
        let config = AlvrViewsConfig(
            ipdMeters: 0.0625,
            fov: [
                AlvrFov(left: -0.91, right: 0.83, up: 0.88, down: -0.84),
                AlvrFov(left: -0.82, right: 0.92, up: 0.89, down: -0.85),
            ])
        let payload = try XCTUnwrap(RuntimeLink.viewConfigPayload(config))

        XCTAssertEqual(payload.count, 36)
        let expected: [Float] = [
            0.0625,
            -0.91, 0.83, 0.88, -0.84,
            -0.82, 0.92, 0.89, -0.85,
        ]
        for (index, value) in expected.enumerated() {
            XCTAssertEqual(payload.readTestF32(at: index * 4), value)
        }
    }

    func testViewConfigPayloadRejectsMalformedCalibration() {
        XCTAssertNil(RuntimeLink.viewConfigPayload(AlvrViewsConfig(
            ipdMeters: 0.063, fov: [
                AlvrFov(left: -.infinity, right: 1, up: 1, down: -1),
                AlvrFov(left: -1, right: 1, up: 1, down: -1),
            ])))
        XCTAssertNil(RuntimeLink.viewConfigPayload(AlvrViewsConfig(
            ipdMeters: 0, fov: [
                AlvrFov(left: -1, right: 1, up: 1, down: -1),
                AlvrFov(left: -1, right: 1, up: 1, down: -1),
            ])))
        XCTAssertNil(RuntimeLink.viewConfigPayload(AlvrViewsConfig(
            ipdMeters: 0.063, fov: [
                AlvrFov(left: -1, right: 1, up: 1, down: -1),
            ])))
    }

    /// parseViewConfig in runtime/pe/control.cpp drops the whole control
    /// connection for a view config outside these bounds, and RuntimeLink
    /// resends the retained config on every Hello, so one bad sample would
    /// keep the runtime disconnected. Pin the mirrored bounds.
    func testViewConfigPayloadEnforcesRuntimeBounds() {
        XCTAssertEqual(RuntimeLink.viewConfigIPDRange, 0.04...0.09)
        XCTAssertEqual(RuntimeLink.maximumViewConfigFovAngle, 1.57079633)

        func payload(ipd: Float = 0.063, left: AlvrFov) -> Data? {
            RuntimeLink.viewConfigPayload(AlvrViewsConfig(
                ipdMeters: ipd,
                fov: [left, AlvrFov(left: -1, right: 1, up: 1, down: -1)]))
        }
        let valid = AlvrFov(left: -1, right: 1, up: 1, down: -1)
        XCTAssertNotNil(payload(ipd: 0.04, left: valid))
        XCTAssertNotNil(payload(ipd: 0.09, left: valid))
        XCTAssertNil(payload(ipd: 0.039, left: valid))
        XCTAssertNil(payload(ipd: 0.091, left: valid))
        XCTAssertNil(payload(ipd: .nan, left: valid))
        XCTAssertNil(payload(left: AlvrFov(left: 1, right: -1, up: 1, down: -1)))
        XCTAssertNil(payload(left: AlvrFov(left: -1, right: 1, up: -1, down: 1)))
        XCTAssertNil(payload(left: AlvrFov(left: 0.5, right: 0.5, up: 1, down: -1)))
        XCTAssertNil(payload(left: AlvrFov(left: -1.6, right: 1, up: 1, down: -1)))
        XCTAssertNil(payload(left: AlvrFov(left: -1, right: 1.6, up: 1, down: -1)))
        XCTAssertNil(payload(left: AlvrFov(left: -1, right: 1, up: 1.6, down: -1)))
        XCTAssertNil(payload(left: AlvrFov(left: -1, right: 1, up: 1, down: -1.6)))
    }

    func testHelloFrameWaitsForAWholeHelloAndKeepsLaterBytes() {
        var frame = Data()
        frame.appendTestU32(2 + 3)
        frame.appendTestU16(RuntimeLink.MessageType.hello.rawValue)
        frame.append(contentsOf: [7, 8, 9])
        XCTAssertEqual(RuntimeLink.helloFrame(in: frame.prefix(5)), .incomplete)
        XCTAssertEqual(RuntimeLink.helloFrame(in: frame.prefix(8)), .incomplete)
        XCTAssertEqual(RuntimeLink.helloFrame(in: frame + Data([1, 2])),
                       .hello(payload: Data([7, 8, 9]), remaining: Data([1, 2])))

        var teardown = Data()
        teardown.appendTestU32(2)
        teardown.appendTestU16(RuntimeLink.MessageType.teardown.rawValue)
        XCTAssertEqual(RuntimeLink.helloFrame(in: teardown), .invalid)
        var oversized = Data()
        oversized.appendTestU32(UInt32(RuntimeLink.maxMessageLength + 1))
        oversized.appendTestU16(RuntimeLink.MessageType.hello.rawValue)
        XCTAssertEqual(RuntimeLink.helloFrame(in: oversized), .invalid)
    }

    func testAuthenticatedHelloReplacesSessionAndSilentConnectionsTimeOut() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("basalt-\(UUID().uuidString).control").path
        let link = try RuntimeLink(controlFilePath: path)
        link.helloTimeout = .milliseconds(300)
        let events = RuntimeLinkEventLog()
        link.onHello = { sessionId, _ in events.append("hello \(sessionId)") }
        link.onTeardown = { events.append("teardown") }
        try await link.start()
        defer { link.stop() }

        let fields = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: " ")
        let port = try XCTUnwrap(UInt16(fields[0]))
        let token = String(fields[1].trimmingCharacters(in: .whitespacesAndNewlines))

        // A silent local connection must not block the runtime.
        let silent = try Self.connectLoopback(port: port)
        defer { close(silent) }
        let first = try Self.connectLoopback(port: port)
        defer { close(first) }
        try Self.sendHello(on: first, token: token, sessionId: 1)
        XCTAssertEqual(try Self.receiveMessageType(from: first),
                       RuntimeLink.MessageType.helloAck.rawValue)

        // Without the token, a connection cannot displace the session.
        let intruder = try Self.connectLoopback(port: port)
        defer { close(intruder) }
        try Self.sendHello(on: intruder, token: String(repeating: "0", count: 32), sessionId: 9)
        XCTAssertNil(try Self.receiveMessageType(from: intruder))

        // A restarted OpenXR session may connect before the old EOF arrives.
        let second = try Self.connectLoopback(port: port)
        defer { close(second) }
        try Self.sendHello(on: second, token: token, sessionId: 2)
        XCTAssertEqual(try Self.receiveMessageType(from: second),
                       RuntimeLink.MessageType.helloAck.rawValue)
        XCTAssertNil(try Self.receiveMessageType(from: first))
        let deadline = Date().addingTimeInterval(1)
        while events.snapshot().count < 3, Date() < deadline { usleep(1_000) }
        XCTAssertEqual(events.snapshot(), ["hello 1", "teardown", "hello 2"])

        // The silent connection was closed by the Hello deadline.
        XCTAssertNil(try Self.receiveMessageType(from: silent))
    }

    private static func connectLoopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BasaltError("socket() failed") }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw BasaltError("connect() failed")
        }
        return fd
    }

    private static func sendHello(on fd: Int32, token: String, sessionId: UInt64) throws {
        var payload = Data()
        payload.appendTestU16(RuntimeLink.protocolVersion)
        payload.append(Data(token.utf8))
        payload.appendTestU64(sessionId)
        payload.appendTestU16(0)
        var message = Data()
        message.appendTestU32(UInt32(2 + payload.count))
        message.appendTestU16(RuntimeLink.MessageType.hello.rawValue)
        message.append(payload)
        let sent = message.withUnsafeBytes { send(fd, $0.baseAddress, message.count, 0) }
        guard sent == message.count else { throw BasaltError("Hello send failed") }
    }

    /// The next message's type, or nil once the link closed the connection.
    private static func receiveMessageType(from fd: Int32) throws -> UInt16? {
        func receive(_ count: Int) throws -> Data? {
            var bytes = [UInt8](repeating: 0, count: count)
            var offset = 0
            while offset < count {
                let received = bytes[offset...].withUnsafeMutableBytes {
                    recv(fd, $0.baseAddress, $0.count, 0)
                }
                if received == 0 || (received < 0 && errno == ECONNRESET) { return nil }
                guard received > 0 else { throw BasaltError("recv timed out") }
                offset += received
            }
            return Data(bytes)
        }
        guard let header = try receive(6) else { return nil }
        let length = Int(header.readTestU32(at: 0))
        guard try receive(max(0, length - 2)) != nil else { return nil }
        return UInt16(header[4]) | (UInt16(header[5]) << 8)
    }
}

private final class RuntimeLinkEventLog: @unchecked Sendable {
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
}

private extension Data {
    mutating func appendTestU16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }

    mutating func appendTestU32(_ value: UInt32) {
        for index in 0..<4 {
            append(UInt8((value >> UInt32(index * 8)) & 0xff))
        }
    }

    mutating func appendTestU64(_ value: UInt64) {
        for index in 0..<8 {
            append(UInt8((value >> UInt64(index * 8)) & 0xff))
        }
    }

    func readTestU64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = (value << 8) | UInt64(self[startIndex + offset + index])
        }
        return value
    }

    func readTestF32(at offset: Int) -> Float {
        var bits: UInt32 = 0
        for index in (0..<4).reversed() {
            bits = (bits << 8) | UInt32(self[startIndex + offset + index])
        }
        return Float(bitPattern: bits)
    }


    func readTestU32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in (0..<4).reversed() {
            value = (value << 8) | UInt32(self[startIndex + offset + index])
        }
        return value
    }
}
