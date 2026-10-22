import XCTest
@testable import BasaltCore

final class AlvrVideoStreamTests: XCTestCase {
    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func duration(seconds: UInt64, nanoseconds: UInt32) -> Data {
        var data = Data()
        appendLittleEndian(seconds, to: &data)
        appendLittleEndian(nanoseconds, to: &data)
        return data
    }

    private static func uplinkDatagram(streamID: UInt16, payload: Data,
                                       shardCount: UInt32 = 1) -> Data {
        var result = Data(repeating: 0, count: 18)
        result.append(payload)
        func write<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            var value = value.bigEndian
            withUnsafeBytes(of: &value) {
                result.replaceSubrange(offset..<offset + $0.count, with: $0)
            }
        }
        write(UInt32(result.count - 4), at: 0)
        write(streamID, at: 4)
        write(UInt32(7), at: 6)
        write(shardCount, at: 10)
        write(UInt32(0), at: 14)
        return result
    }

    func testDecodesTrackingTimestampAndClientStatistics() throws {
        let tracking = Self.uplinkDatagram(
            streamID: 0,
            payload: Self.duration(seconds: 12, nanoseconds: 345))
        XCTAssertEqual(try AlvrUplinkPacketDecoder.decode(tracking),
                       .tracking(timestampNanoseconds: 12_000_000_345, headPose: nil,
                                 leftController: nil, rightController: nil,
                                 controllerMask: 0))

        var statisticsPayload = Data()
        for value: UInt32 in [1, 14_000_000, 5_000_000, 2_000_000,
                              3_000_000, 6_000_000, 40_000_000] {
            statisticsPayload.append(Self.duration(seconds: 0, nanoseconds: value))
        }
        let statisticsPacket = Self.uplinkDatagram(streamID: 4, payload: statisticsPayload)
        guard case .statistics(let statistics) =
                try AlvrUplinkPacketDecoder.decode(statisticsPacket) else {
            return XCTFail("Expected ALVR client statistics")
        }
        XCTAssertEqual(statistics.targetTimestampNanoseconds, 1)
        XCTAssertEqual(statistics.frameIntervalNanoseconds, 14_000_000)
        XCTAssertEqual(statistics.videoDecodeNanoseconds, 5_000_000)
        XCTAssertEqual(statistics.videoDecoderQueueNanoseconds, 2_000_000)
        XCTAssertEqual(statistics.totalPipelineLatencyNanoseconds, 40_000_000)
    }

    func testDecodesHeadPoseFromFirstTrackingMotion() throws {
        var payload = Self.duration(seconds: 2, nanoseconds: 3)
        Self.appendLittleEndian(UInt64(1), to: &payload) // device motion count
        Self.appendLittleEndian(UInt64(0x5b90_853d_c920_2538), to: &payload) // HEAD id
        for value: Float in [0, 0.258819, 0, 0.965926, 1, 2, 3, 0, 0, 0, 0, 0, 0] {
            Self.appendLittleEndian(value.bitPattern, to: &payload)
        }
        let packet = Self.uplinkDatagram(streamID: 0, payload: payload)
        guard case .tracking(let timestamp, let pose?, _, _, let mask) =
                try AlvrUplinkPacketDecoder.decode(packet) else {
            return XCTFail("Expected tracking pose")
        }
        XCTAssertEqual(timestamp, 2_000_000_003)
        XCTAssertEqual(pose.orientationY, 0.258819, accuracy: 0.000001)
        XCTAssertEqual(pose.orientationW, 0.965926, accuracy: 0.000001)
        XCTAssertEqual(pose.positionX, 1)
        XCTAssertEqual(pose.positionY, 2)
        XCTAssertEqual(pose.positionZ, 3)
        XCTAssertEqual(mask, 0)
    }

    func testDecodesControllerMotionsByDeviceID() throws {
        var payload = Self.duration(seconds: 3, nanoseconds: 4)
        Self.appendLittleEndian(UInt64(2), to: &payload)

        func appendMotion(id: UInt64, position: (Float, Float, Float),
                          velocity: (Float, Float, Float)) {
            Self.appendLittleEndian(id, to: &payload)
            let values: [Float] = [
                0, 0, 0, 1, position.0, position.1, position.2,
                velocity.0, velocity.1, velocity.2, 0.1, 0.2, 0.3,
            ]
            for value in values { Self.appendLittleEndian(value.bitPattern, to: &payload) }
        }

        // Reverse the normal left/right order to prove IDs, not indices, are used.
        appendMotion(id: 0xf6b8_1330_eb3d_bdd8, position: (1, 2, 3),
                     velocity: (4, 5, 6))
        appendMotion(id: 0xe521_d8da_be2d_07a2, position: (-1, -2, -3),
                     velocity: (-4, -5, -6))

        let packet = Self.uplinkDatagram(streamID: 0, payload: payload)
        guard case .tracking(let timestamp, _, let left?, let right?, let mask) =
                try AlvrUplinkPacketDecoder.decode(packet) else {
            return XCTFail("Expected both controller motions")
        }
        XCTAssertEqual(timestamp, 3_000_000_004)
        XCTAssertEqual(left.pose.positionX, -1)
        XCTAssertEqual(left.linearVelocityZ, -6)
        XCTAssertEqual(right.pose.positionZ, 3)
        XCTAssertEqual(right.angularVelocityY, 0.2, accuracy: 0.000001)
        XCTAssertEqual(mask, 3)
    }

    func testDecodesControllerPrefixFromShardedTrackingVector() throws {
        var payload = Self.duration(seconds: 4, nanoseconds: 5)
        Self.appendLittleEndian(UInt64(20), to: &payload) // body motions continue later
        for (id, x) in [
            (UInt64(0x5b90_853d_c920_2538), Float(0)),
            (UInt64(0xe521_d8da_be2d_07a2), Float(-0.2)),
            (UInt64(0xf6b8_1330_eb3d_bdd8), Float(0.2)),
        ] {
            Self.appendLittleEndian(id, to: &payload)
            for value: Float in [0, 0, 0, 1, x, 1.2, -0.4, 0, 0, 0, 0, 0, 0] {
                Self.appendLittleEndian(value.bitPattern, to: &payload)
            }
        }
        let packet = Self.uplinkDatagram(
            streamID: 0, payload: payload, shardCount: 2)
        guard case .tracking(_, let head?, let left?, let right?, let mask) =
                try AlvrUplinkPacketDecoder.decode(packet) else {
            return XCTFail("Expected the complete HMD/controller prefix")
        }
        XCTAssertEqual(head.positionY, 1.2)
        XCTAssertEqual(left.pose.positionX, -0.2)
        XCTAssertEqual(right.pose.positionX, 0.2)
        XCTAssertEqual(mask, 3)
    }

    func testControllerMaskReflectsMissingHandByDeviceID() throws {
        var payload = Self.duration(seconds: 5, nanoseconds: 6)
        Self.appendLittleEndian(UInt64(2), to: &payload)
        for id in [UInt64(0x5b90_853d_c920_2538),
                   UInt64(0xf6b8_1330_eb3d_bdd8)] {
            Self.appendLittleEndian(id, to: &payload)
            for value: Float in [0, 0, 0, 1, 0, 1, -0.4, 0, 0, 0, 0, 0, 0] {
                Self.appendLittleEndian(value.bitPattern, to: &payload)
            }
        }

        guard case .tracking(_, _, nil, let right?, let mask) =
                try AlvrUplinkPacketDecoder.decode(
                    Self.uplinkDatagram(streamID: 0, payload: payload)) else {
            return XCTFail("Expected only the right controller")
        }
        XCTAssertEqual(right.pose.positionY, 1)
        XCTAssertEqual(mask, 2)
    }

    func testSendsPacketizedVideoOverUDP() throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(receiver, 0)
        defer { close(receiver) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(receiver, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        var bound = sockaddr_in()
        var boundSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(receiver, $0, &boundSize)
            }
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        let sender = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: UInt16(bigEndian: bound.sin_port), localPort: 0)
        sender.send(annexB: Data([0, 0, 0, 1, 0x65]),
                    timestampNanoseconds: 1, isIDR: true)

        var buffer = [UInt8](repeating: 0, count: 2_048)
        let count = recv(receiver, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(count, 18)
        XCTAssertEqual(Data(buffer[4..<6]), Data([0, 3]))
        XCTAssertEqual(Data(buffer[10..<14]), Data([0, 0, 0, 1]))
    }

    func testSendsAndReceivesLengthFramedStreamPacketsOverTCP() throws {
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

        let sender = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: UInt16(bigEndian: bound.sin_port),
            localPort: 0, transport: .tcp)
        XCTAssertEqual(sender.transport, .tcp)
        let peer = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        let reportReceived = expectation(description: "completed access-unit report")
        sender.onFrameSent = { report in
            XCTAssertEqual(report.timestampNanoseconds, 1)
            XCTAssertEqual(report.accessUnitBytes, 5)
            XCTAssertGreaterThan(report.wireBytes, report.accessUnitBytes)
            XCTAssertEqual(report.shardCount, 1)
            XCTAssertTrue(report.isIDR)
            XCTAssertGreaterThan(report.durationNanoseconds, 0)
            reportReceived.fulfill()
        }
        sender.send(annexB: Data([0, 0, 0, 1, 0x65]),
                    timestampNanoseconds: 1, isIDR: true)
        let prefix = try readExactly(4, from: peer)
        let payloadLength = prefix.reduce(0) { ($0 << 8) | Int($1) }
        let payload = try readExactly(payloadLength, from: peer)
        XCTAssertEqual(payload.prefix(2), Data([0, 3]))
        XCTAssertEqual(payload[6..<10], Data([0, 0, 0, 1]))

        let pcm = Data([0x00, 0x80, 0xff, 0x7f])
        XCTAssertTrue(sender.sendAudioPCM16(pcm))
        let audioPrefix = try readExactly(4, from: peer)
        let audioPayloadLength = audioPrefix.reduce(0) { ($0 << 8) | Int($1) }
        let audioPayload = try readExactly(audioPayloadLength, from: peer)
        XCTAssertEqual(audioPayload.prefix(2), Data([0, 2]))
        XCTAssertEqual(audioPayload[2..<6], Data([0, 0, 0, 0]))
        XCTAssertEqual(audioPayload[6..<10], Data([0, 0, 0, 1]))
        XCTAssertEqual(audioPayload[10..<14], Data([0, 0, 0, 0]))
        XCTAssertEqual(audioPayload[14...], pcm)

        let questTimestamp: UInt64 = 12_000_000_345
        let tracking = Self.uplinkDatagram(
            streamID: 0,
            payload: Self.duration(seconds: 12, nanoseconds: 345))
        tracking.withUnsafeBytes {
            XCTAssertEqual(Darwin.send(peer, $0.baseAddress, tracking.count, 0), tracking.count)
        }
        let deadline = Date().addingTimeInterval(1)
        var videoTimestamp: UInt64?
        while videoTimestamp == nil, Date() < deadline {
            videoTimestamp = sender.timestampForVideoFrame()
            usleep(1_000)
        }
        XCTAssertEqual(videoTimestamp, questTimestamp)
        XCTAssertEqual(sender.timestampForVideoFrame(), questTimestamp)
        wait(for: [reportReceived], timeout: 1)
    }

    func testWiredBufferPolicyCanHoldAnIDRWithoutGrowingUDPQueue() {
        XCTAssertEqual(AlvrVideoStreamSender.udpSendBufferBytes, 64 * 1_024)
        XCTAssertEqual(AlvrVideoStreamSender.tcpSendBufferBytes, 1 * 1_024 * 1_024)
        XCTAssertEqual(AlvrVideoStreamSender.tcpReceiveBufferBytes, 1 * 1_024 * 1_024)
        XCTAssertGreaterThan(AlvrVideoStreamSender.tcpSendBufferBytes,
                             AlvrVideoStreamSender.udpSendBufferBytes)
        // The USB stream gives up no sooner than the control connection's
        // silence timeout; a shorter limit turned headset hiccups into
        // self-inflicted disconnects.
        XCTAssertEqual(AlvrVideoStreamSender.defaultTCPStallTimeoutNanoseconds,
                       AlvrSessionHandshakeResult.defaultReceiveTimeoutNanoseconds)
    }

    /// Regression for bidirectional USB stalls during Quest streaming: the adb USB
    /// stream can pause in both directions while the ALVR client still renders
    /// at full rate. The old 50 ms whole-access-unit deadline turned such
    /// pauses into "Timed out writing one ALVR USB video access unit"
    /// disconnects (flicker plus tracking loss each time). A pause must only
    /// delay the frame, keep tracking flowing, and leave the stream usable.
    func testWiredStreamSurvivesAHeadsetReadPauseAndKeepsTrackingFlowing() throws {
        let (listener, port) = try Self.makeLoopbackListener(receiveBufferBytes: 4 * 1_024)
        defer { close(listener) }
        let sender = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: port, localPort: 0, transport: .tcp)
        let peer = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        let transportClosed = expectation(description: "transport closed")
        transportClosed.isInverted = true
        sender.onTransportClosed = { _ in transportClosed.fulfill() }
        sender.onError = { error in XCTFail("unexpected send error: \(error)") }
        let lock = NSLock()
        var sentReports = [AlvrVideoSendReport]()
        sender.onFrameSent = { report in
            lock.lock()
            sentReports.append(report)
            lock.unlock()
        }
        let trackingDuringPause = expectation(description: "tracking read while the write waits")
        sender.onTrackingTimestamp = { timestamp in
            if timestamp == 12_000_000_345 { trackingDuringPause.fulfill() }
        }

        // Much larger than every socket buffer, so the write must wait for
        // the headset to read.
        let accessUnit = Data([0, 0, 0, 1, 0x65])
            + Data(repeating: 0x55, count: 8 * 1_024 * 1_024)
        XCTAssertTrue(sender.send(annexB: accessUnit, timestampNanoseconds: 1, isIDR: true))

        // The headset reads nothing for six times the old deadline but keeps
        // sending tracking, as the Quest did during each hiccup.
        usleep(150_000)
        let tracking = Self.uplinkDatagram(
            streamID: 0, payload: Self.duration(seconds: 12, nanoseconds: 345))
        tracking.withUnsafeBytes {
            XCTAssertEqual(Darwin.send(peer, $0.baseAddress, tracking.count, 0), tracking.count)
        }
        wait(for: [trackingDuringPause], timeout: 1)
        usleep(150_000)
        lock.lock()
        XCTAssertTrue(sentReports.isEmpty, "the access unit cannot finish while unread")
        lock.unlock()

        // The headset resumes reading: the whole access unit arrives intact.
        let expectedWireBytes = try AlvrVideoPacketizer.shards(
            annexB: accessUnit, timestampNanoseconds: 1, isIDR: true, packetIndex: 0)
            .reduce(0) { $0 + $1.count }
        var shardsRead = 0
        var bytesRead = 0
        while bytesRead < expectedWireBytes {
            let prefix = try readExactly(4, from: peer)
            let payloadLength = prefix.reduce(0) { ($0 << 8) | Int($1) }
            let payload = try readExactly(payloadLength, from: peer)
            XCTAssertEqual(payload.prefix(2), Data([0, 3]))
            bytesRead += 4 + payloadLength
            shardsRead += 1
        }
        XCTAssertEqual(bytesRead, expectedWireBytes)

        // The stream is still usable: the next frame is framed correctly.
        let deadline = Date().addingTimeInterval(2)
        var sent = false
        while !sent, Date() < deadline {
            sent = sender.send(annexB: Data([0, 0, 0, 1, 0x41]),
                               timestampNanoseconds: 2, isIDR: false)
            if !sent { usleep(1_000) }
        }
        XCTAssertTrue(sent)
        let nextPrefix = try readExactly(4, from: peer)
        let nextPayload = try readExactly(
            nextPrefix.reduce(0) { ($0 << 8) | Int($1) }, from: peer)
        XCTAssertEqual(nextPayload.prefix(2), Data([0, 3]))
        XCTAssertEqual(nextPayload[2..<6], Data([0, 0, 0, 1]), "next packet index")
        XCTAssertEqual(nextPayload[6..<10], Data([0, 0, 0, 1]), "one shard")
        lock.lock()
        XCTAssertEqual(sentReports.first?.shardCount, shardsRead)
        lock.unlock()
        wait(for: [transportClosed], timeout: 0.2)
    }

    func testWiredStreamFailsOnceTheHeadsetReadsNothingForTheStallTimeout() throws {
        let (listener, port) = try Self.makeLoopbackListener(receiveBufferBytes: 4 * 1_024)
        defer { close(listener) }
        let sender = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: port, localPort: 0, transport: .tcp,
            tcpStallTimeoutNanoseconds: 200_000_000)
        let peer = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }

        let failed = expectation(description: "stalled stream reported")
        sender.onError = { error in
            XCTAssertTrue(error.localizedDescription.contains("stalled"),
                          error.localizedDescription)
            failed.fulfill()
        }
        let closed = expectation(description: "transport closed once")
        sender.onTransportClosed = { _ in closed.fulfill() }
        XCTAssertTrue(sender.send(
            annexB: Data(repeating: 0x55, count: 8 * 1_024 * 1_024),
            timestampNanoseconds: 1, isIDR: true))
        wait(for: [failed, closed], timeout: 3)

        // Once any TCP frame is partial, sending another frame would corrupt
        // the stream. The sender remains failed until the session reconnects.
        XCTAssertFalse(sender.send(
            annexB: Data([0, 0, 0, 1, 0x41]),
            timestampNanoseconds: 2, isIDR: false))
    }

    func testClosingDuringAStalledWiredWriteReturnsPromptly() throws {
        let (listener, port) = try Self.makeLoopbackListener(receiveBufferBytes: 4 * 1_024)
        defer { close(listener) }
        let sender = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: port, localPort: 0, transport: .tcp,
            tcpStallTimeoutNanoseconds: 30_000_000_000)
        let peer = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        sender.onTransportClosed = { reason in
            XCTFail("close() must not report a transport failure: \(reason)")
        }
        XCTAssertTrue(sender.send(
            annexB: Data(repeating: 0x55, count: 8 * 1_024 * 1_024),
            timestampNanoseconds: 1, isIDR: true))
        usleep(100_000)

        let started = Date()
        sender.close()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertFalse(sender.send(
            annexB: Data([0, 0, 0, 1, 0x41]),
            timestampNanoseconds: 2, isIDR: false))
    }

    /// The streamer skips encoding while a USB write is paused, and treats a
    /// frame the router could not hand over as lost (`VideoLossRecoveryGate`).
    func testPausedWiredWriteReportsBusyAndTheRouterReportsTheLostFrame() throws {
        let router = AlvrVideoStreamRouter()
        XCTAssertFalse(router.isBusy(requiringTrackingTimestamp: true), "no stream installed")
        XCTAssertTrue(router.send(annexB: Data([0, 0, 0, 1, 0x41]), isIDR: false))

        let (listener, port) = try Self.makeLoopbackListener(receiveBufferBytes: 4 * 1_024)
        defer { close(listener) }
        let sender = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: port, localPort: 0, transport: .tcp,
            tcpStallTimeoutNanoseconds: 30_000_000_000)
        let peer = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        var controlSockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &controlSockets), 0)
        defer { close(controlSockets[1]) }
        let control = AlvrSessionHandshakeResult(clientState: .standby,
                                                 negotiatedSettings: nil,
                                                 streamReady: true,
                                                 socket: controlSockets[0])
        router.install(sender, controlSession: control)
        defer { sender.close() }

        XCTAssertFalse(sender.isBusy)
        XCTAssertFalse(router.isBusy(requiringTrackingTimestamp: false))
        XCTAssertTrue(router.isBusy(requiringTrackingTimestamp: true),
                      "desktop frames need a tracking timestamp")
        XCTAssertFalse(router.send(annexB: Data([0, 0, 0, 1, 0x41]), isIDR: false),
                       "no tracking timestamp: the frame is lost")

        XCTAssertTrue(router.send(
            annexB: Data(repeating: 0x55, count: 8 * 1_024 * 1_024),
            isIDR: false, timestampNanoseconds: 1))
        usleep(100_000)
        XCTAssertTrue(sender.isBusy, "the headset is not reading")
        XCTAssertTrue(router.isBusy(requiringTrackingTimestamp: false))
        XCTAssertFalse(router.send(annexB: Data([0, 0, 0, 1, 0x41]), isIDR: false,
                                   timestampNanoseconds: 2))
    }

    /// A write that started less than one frame period ago is not "busy":
    /// the next access unit waits behind it (one at most) instead of being
    /// dropped before encoding.
    func testShortInFlightWiredWriteIsNotBusyAndQueuesOneAccessUnit() throws {
        let (listener, port) = try Self.makeLoopbackListener(receiveBufferBytes: 4 * 1_024)
        defer { close(listener) }
        let sender = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: port, localPort: 0, transport: .tcp,
            tcpStallTimeoutNanoseconds: 30_000_000_000,
            inFlightBusyAfterNanoseconds: 30_000_000_000)
        let peer = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        defer { sender.close() }
        let lock = NSLock()
        var drops = 0
        sender.onFrameDropped = {
            lock.lock()
            drops += 1
            lock.unlock()
        }
        var sentPacketIndices = [Int]()
        let bothSent = expectation(description: "both access units written")
        bothSent.expectedFulfillmentCount = 2
        sender.onFrameSent = { report in
            lock.lock()
            sentPacketIndices.append(Int(report.timestampNanoseconds))
            lock.unlock()
            bothSent.fulfill()
        }

        let accessUnit = Data([0, 0, 0, 1, 0x65])
            + Data(repeating: 0x55, count: 8 * 1_024 * 1_024)
        XCTAssertTrue(sender.send(annexB: accessUnit, timestampNanoseconds: 1, isIDR: true))
        usleep(50_000)
        XCTAssertFalse(sender.isBusy, "the write in flight is younger than its busy threshold")
        XCTAssertTrue(sender.send(annexB: Data([0, 0, 0, 1, 0x41]),
                                  timestampNanoseconds: 2, isIDR: false),
                      "queued behind the write in flight")
        XCTAssertTrue(sender.isBusy, "the one queue slot is taken")
        XCTAssertFalse(sender.send(annexB: Data([0, 0, 0, 1, 0x41]),
                                   timestampNanoseconds: 3, isIDR: false),
                       "never more than one access unit waits")
        lock.lock()
        XCTAssertEqual(drops, 1)
        lock.unlock()

        // The headset reads again: both access units arrive, in order.
        let firstWireBytes = try AlvrVideoPacketizer.shards(
            annexB: accessUnit, timestampNanoseconds: 1, isIDR: true, packetIndex: 0)
            .reduce(0) { $0 + $1.count }
        var bytesRead = 0
        while bytesRead < firstWireBytes {
            let prefix = try readExactly(4, from: peer)
            bytesRead += 4 + (try readExactly(
                prefix.reduce(0) { ($0 << 8) | Int($1) }, from: peer)).count
        }
        let nextPrefix = try readExactly(4, from: peer)
        let nextPayload = try readExactly(
            nextPrefix.reduce(0) { ($0 << 8) | Int($1) }, from: peer)
        XCTAssertEqual(nextPayload[2..<6], Data([0, 0, 0, 1]), "next packet index")
        wait(for: [bothSent], timeout: 2)
        lock.lock()
        XCTAssertEqual(sentPacketIndices, [1, 2])
        lock.unlock()
        let deadline = Date().addingTimeInterval(1)
        while sender.isBusy, Date() < deadline { usleep(1_000) }
        XCTAssertFalse(sender.isBusy)
    }

    /// A write older than one frame period is a real stall: frames are not
    /// encoded, and an encoded frame handed over now is dropped (which starts
    /// the IDR recovery in the streamer).
    func testLongInFlightWiredWriteIsBusyAndDropsTheNextAccessUnit() throws {
        let (listener, port) = try Self.makeLoopbackListener(receiveBufferBytes: 4 * 1_024)
        defer { close(listener) }
        let sender = try AlvrVideoStreamSender(
            host: "127.0.0.1", remotePort: port, localPort: 0, transport: .tcp,
            tcpStallTimeoutNanoseconds: 30_000_000_000,
            inFlightBusyAfterNanoseconds: 20_000_000)
        let peer = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        defer { sender.close() }
        let dropped = expectation(description: "frame dropped")
        sender.onFrameDropped = { dropped.fulfill() }

        XCTAssertTrue(sender.send(
            annexB: Data(repeating: 0x55, count: 8 * 1_024 * 1_024),
            timestampNanoseconds: 1, isIDR: true))
        usleep(100_000)
        XCTAssertTrue(sender.isBusy, "the headset has read nothing for 100 ms")
        XCTAssertFalse(sender.send(annexB: Data([0, 0, 0, 1, 0x41]),
                                   timestampNanoseconds: 2, isIDR: false))
        wait(for: [dropped], timeout: 1)
    }

    private static func makeLoopbackListener(receiveBufferBytes: Int32? = nil) throws
        -> (listener: Int32, port: UInt16) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw BasaltError("socket() failed") }
        if var receiveBuffer = receiveBufferBytes {
            setsockopt(listener, SOL_SOCKET, SO_RCVBUF, &receiveBuffer,
                       socklen_t(MemoryLayout<Int32>.size))
        }
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
        guard bindResult == 0, listen(listener, 1) == 0 else {
            close(listener)
            throw BasaltError("Cannot listen on loopback")
        }
        var bound = sockaddr_in()
        var boundSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(listener, $0, &boundSize)
            }
        }
        return (listener, UInt16(bigEndian: bound.sin_port))
    }

    private func readExactly(_ count: Int, from socket: Int32) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            let received = result.withUnsafeMutableBytes {
                recv(socket, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            guard received > 0 else { throw BasaltError("Loopback TCP peer closed") }
            offset += received
        }
        return result
    }
}
