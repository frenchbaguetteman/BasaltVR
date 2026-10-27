import XCTest
@testable import BasaltCore

final class AlvrControlTests: XCTestCase {
    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func acceptedPrefix(protocolId: UInt64, name: String) -> Data {
        let nameData = Data(name.utf8)
        var packet = littleEndian(UInt32(0))
        packet.append(littleEndian(protocolId))
        packet.append(littleEndian(UInt64(nameData.count)))
        packet.append(nameData)
        packet.append(littleEndian(UInt32(0))) // IpAddr::V4
        packet.append(contentsOf: [192, 168, 1, 10])
        return packet
    }

    private static func framed(_ payload: Data) -> Data {
        var result = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }

    private static func receiveExactly(_ count: Int, fd: Int32) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            guard received > 0 else { return nil }
            offset += received
        }
        return data
    }

    private static func receiveFrame(fd: Int32) -> Data? {
        guard let prefix = receiveExactly(4, fd: fd) else { return nil }
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        return receiveExactly(length, fd: fd)
    }

    func testDecodesAcceptedPacketPrefix() throws {
        var packet = Self.acceptedPrefix(protocolId: 0x0123_4567_89AB_CDEF, name: "Quest 3")
        packet.append(0) // None

        XCTAssertEqual(try AlvrClientConnectionDecoder.decode(packet),
                       .accepted(protocolId: 0x0123_4567_89AB_CDEF, displayName: "Quest 3",
                                 serverIP: "192.168.1.10", capabilities: nil))
    }

    func testDecodesVideoCapabilitiesAndEmbeddedJSON() throws {
        var packet = Self.acceptedPrefix(protocolId: 20, name: "Quest 3")
        packet.append(1) // Some
        packet.append(Self.littleEndian(UInt32(2064)))
        packet.append(Self.littleEndian(UInt32(2208)))

        let json = Data("{\"encoder_av1\":false,\"prefer_full_range\":false}".utf8)
        packet.append(Self.littleEndian(UInt64(2 + json.count)))
        for rate: Float in [72, 90] { packet.append(Self.littleEndian(rate.bitPattern)) }
        for byte in json { packet.append(Self.littleEndian((-Float(byte)).bitPattern)) }
        packet.append(Self.littleEndian(UInt32(48_000)))

        guard case .accepted(_, _, _, let capabilities?) =
                try AlvrClientConnectionDecoder.decode(packet) else {
            return XCTFail("Expected accepted capabilities")
        }
        XCTAssertEqual(capabilities.width, 2064)
        XCTAssertEqual(capabilities.height, 2208)
        XCTAssertEqual(capabilities.refreshRates, [72, 90])
        XCTAssertEqual(capabilities.microphoneSampleRate, 48_000)
        XCTAssertFalse(capabilities.supportsAV1)
        XCTAssertFalse(capabilities.prefersFullRange)
        XCTAssertTrue(capabilities.supportsHighProfile)
    }

    func testUnusableEncodingGammaFallsBackBeforeReachingStreamConfigJSON() throws {
        func capabilities(gammaJSON: String) throws -> AlvrVideoCapabilities {
            var packet = Self.acceptedPrefix(protocolId: 20, name: "Quest 3")
            packet.append(1) // Some
            packet.append(Self.littleEndian(UInt32(2064)))
            packet.append(Self.littleEndian(UInt32(2208)))
            let json = Data("{\"preferred_encoding_gamma\":\(gammaJSON)}".utf8)
            packet.append(Self.littleEndian(UInt64(1 + json.count)))
            packet.append(Self.littleEndian(Float(90).bitPattern))
            for byte in json { packet.append(Self.littleEndian((-Float(byte)).bitPattern)) }
            packet.append(Self.littleEndian(UInt32(48_000)))
            guard case .accepted(_, _, _, let capabilities?) =
                    try AlvrClientConnectionDecoder.decode(packet) else {
                throw BasaltError("Expected accepted capabilities")
            }
            return capabilities
        }

        XCTAssertEqual(try capabilities(gammaJSON: "2.2").preferredEncodingGamma, 2.2)
        // 1e39 overflows Float to +inf, which JSONSerialization cannot encode.
        for unusable in ["1e39", "-1", "0", "1000"] {
            let decoded = try capabilities(gammaJSON: unusable)
            XCTAssertEqual(decoded.preferredEncodingGamma, 1, unusable)
            let settings = try AlvrNegotiatedSettings.beatSaberDefaults(for: decoded)
            XCTAssertNoThrow(try AlvrStreamConfigEncoder.payload(settings: settings))
        }
    }

    func testDecodesStandby() throws {
        XCTAssertEqual(try AlvrClientConnectionDecoder.decode(Self.littleEndian(UInt32(1))), .standby)
    }

    func testDecodesStreamingControlEvents() throws {
        XCTAssertEqual(try AlvrClientControlDecoder.decode(Self.littleEndian(UInt32(1))),
                       .requestIDR)
        XCTAssertEqual(try AlvrClientControlDecoder.decode(Self.littleEndian(UInt32(2))),
                       .keepAlive)

        var views = Self.littleEndian(UInt32(4))
        for value: Float in [0.064, -0.9, 1.0, 0.8, -0.8,
                             -1.0, 0.9, 0.8, -0.8] {
            views.append(Self.littleEndian(value.bitPattern))
        }
        guard case .viewsConfig(let config) = try AlvrClientControlDecoder.decode(views) else {
            return XCTFail("Expected ALVR views configuration")
        }
        XCTAssertEqual(config.ipdMeters, 0.064, accuracy: 0.0001)
        XCTAssertEqual(config.fov.count, 2)
        XCTAssertEqual(config.fov[0].left, -0.9)
        XCTAssertEqual(config.fov[1].right, 0.9)

        var buttons = Self.littleEndian(UInt32(7))
        buttons.append(Self.littleEndian(UInt64(2)))
        buttons.append(Self.littleEndian(UInt64(0x1111)))
        buttons.append(Self.littleEndian(UInt32(0)))
        buttons.append(1)
        buttons.append(Self.littleEndian(UInt64(0x2222)))
        buttons.append(Self.littleEndian(UInt32(1)))
        buttons.append(Self.littleEndian(Float(0.75).bitPattern))
        XCTAssertEqual(try AlvrClientControlDecoder.decode(buttons), .buttons([
            AlvrButtonEntry(pathID: 0x1111, value: .binary(true)),
            AlvrButtonEntry(pathID: 0x2222, value: .scalar(0.75)),
        ]))

        var profile = Self.littleEndian(UInt32(8))
        profile.append(Self.littleEndian(UInt64(0xe521_d8da_be2d_07a2)))
        profile.append(Self.littleEndian(UInt64(0x0812_fd85_c843_84a6)))
        XCTAssertEqual(try AlvrClientControlDecoder.decode(profile),
                       .activeInteractionProfile(
                           deviceID: 0xe521_d8da_be2d_07a2,
                           profileID: 0x0812_fd85_c843_84a6))
    }

    func testLiveControlSessionDispatchesIDRAndViewsConfig() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[1]) }

        let session = AlvrSessionHandshakeResult(clientState: .standby,
                                                 negotiatedSettings: nil,
                                                 streamReady: true,
                                                 socket: sockets[0])
        let idrReceived = expectation(description: "IDR request dispatched")
        let viewsReceived = expectation(description: "views config dispatched")
        session.onRequestIDR { idrReceived.fulfill() }
        session.onViewsConfig { config in
            XCTAssertEqual(config.ipdMeters, 0.064, accuracy: 0.0001)
            viewsReceived.fulfill()
        }

        var views = Self.littleEndian(UInt32(4))
        for value: Float in [0.064, -0.9, 1.0, 0.8, -0.8,
                             -1.0, 0.9, 0.8, -0.8] {
            views.append(Self.littleEndian(value.bitPattern))
        }
        let packets = Self.framed(Self.littleEndian(UInt32(1))) + Self.framed(views)
        XCTAssertEqual(packets.withUnsafeBytes {
            send(sockets[1], $0.baseAddress, packets.count, 0)
        }, packets.count)

        await fulfillment(of: [idrReceived, viewsReceived], timeout: 2)
        withExtendedLifetime(session) {}
    }

    func testLiveControlSessionReportsDisconnectOnce() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)

        let session = AlvrSessionHandshakeResult(clientState: .standby,
                                                 negotiatedSettings: nil,
                                                 streamReady: true,
                                                 socket: sockets[0])
        let disconnected = expectation(description: "control disconnect dispatched")
        disconnected.expectedFulfillmentCount = 1
        session.onDisconnect { disconnected.fulfill() }

        close(sockets[1])
        sockets[1] = -1
        await fulfillment(of: [disconnected], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        withExtendedLifetime(session) {}
    }

    func testLiveControlButtonCacheIsBoundedAndUpdatesExistingPaths() {
        var values: [UInt64: AlvrButtonValue] = [:]
        let initial = (1...65).map {
            AlvrButtonEntry(pathID: UInt64($0), value: .scalar(Float($0)))
        }
        let retained = AlvrSessionHandshakeResult.retainButtonEntries(
            initial, in: &values)
        XCTAssertEqual(retained.count,
                       AlvrSessionHandshakeResult.maximumRetainedButtonPaths)
        XCTAssertEqual(values.count,
                       AlvrSessionHandshakeResult.maximumRetainedButtonPaths)
        XCTAssertNil(values[65])

        let update = AlvrButtonEntry(pathID: 1, value: .scalar(0.25))
        XCTAssertEqual(AlvrSessionHandshakeResult.retainButtonEntries(
            [update], in: &values), [update])
        XCTAssertEqual(values[1], .scalar(0.25))
    }

    func testRejectsMalformedPackets() {
        XCTAssertThrowsError(try AlvrClientConnectionDecoder.decode(Data()))
        XCTAssertThrowsError(try AlvrClientConnectionDecoder.decode(Self.littleEndian(UInt32(99))))

        var hugeString = Self.littleEndian(UInt32(0))
        hugeString.append(Self.littleEndian(UInt64(1)))
        hugeString.append(Self.littleEndian(UInt64(4_097)))
        XCTAssertThrowsError(try AlvrClientConnectionDecoder.decode(hugeString))
    }

    func testProbeReadsFramedPacketOverLoopback() async throws {
        let server = try TCPServer(port: 0, bindHost: "127.0.0.1")
        defer { server.stop() }
        try await server.start()

        var payload = Self.acceptedPrefix(protocolId: 42, name: "Loopback Quest")
        payload.append(0)

        var framed = Data()
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        server.onClientConnected = { server.broadcast(framed) }

        let result = try await AlvrControlProbe.connect(
            host: "127.0.0.1", port: try XCTUnwrap(server.port))
        XCTAssertEqual(result, .accepted(protocolId: 42, displayName: "Loopback Quest",
                                         serverIP: "192.168.1.10", capabilities: nil))
    }

    func testNegotiatesUntilStreamReadyOverOneConnection() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var bound = sockaddr_in()
        var boundSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(listener, $0, &boundSize)
            }
        }

        let serverFinished = expectation(description: "mock headset completed handshake")
        DispatchQueue.global().async {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }

            var accepted = Self.acceptedPrefix(protocolId: 42, name: "Mock Quest")
            accepted.append(1)
            accepted.append(Self.littleEndian(UInt32(1680)))
            accepted.append(Self.littleEndian(UInt32(1760)))
            accepted.append(Self.littleEndian(UInt64(1)))
            accepted.append(Self.littleEndian(Float(90).bitPattern))
            accepted.append(Self.littleEndian(UInt32(44_100)))
            let packet = Self.framed(accepted)
            _ = packet.withUnsafeBytes { send(client, $0.baseAddress, packet.count, 0) }

            guard Self.receiveFrame(fd: client) != nil,
                  Self.receiveFrame(fd: client) == Data([0, 0, 0, 0]) else { return }
            let ready = Self.framed(Data([3, 0, 0, 0]))
            _ = ready.withUnsafeBytes { send(client, $0.baseAddress, ready.count, 0) }
            serverFinished.fulfill()
        }

        let result = try await AlvrControlProbe.negotiateSession(
            host: "127.0.0.1", port: UInt16(bigEndian: bound.sin_port))
        XCTAssertTrue(result.streamReady)
        XCTAssertEqual(result.negotiatedSettings?.refreshRate, 90)
        await fulfillment(of: [serverFinished], timeout: 5)
    }

    func testProbeGateSuppressesOverlapAndCompletedClients() {
        let gate = AlvrControlProbeGate()
        XCTAssertTrue(gate.begin(clientKey: "quest@127.0.0.1"))
        XCTAssertFalse(gate.begin(clientKey: "quest@127.0.0.1"))

        gate.finish(clientKey: "quest@127.0.0.1", succeeded: false)
        XCTAssertTrue(gate.begin(clientKey: "quest@127.0.0.1"))

        gate.finish(clientKey: "quest@127.0.0.1", succeeded: true)
        XCTAssertFalse(gate.begin(clientKey: "quest@127.0.0.1"))
        XCTAssertTrue(gate.begin(clientKey: "another@127.0.0.1"))
    }
}
