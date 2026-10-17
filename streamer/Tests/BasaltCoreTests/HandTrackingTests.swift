import XCTest
import simd
@testable import BasaltCore

final class HandTrackingTests: XCTestCase {
    // MARK: helpers

    private static func le<T: FixedWidthInteger>(_ value: T, _ data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func f32(_ value: Float, _ data: inout Data) { le(value.bitPattern, &data) }

    private static func pose(_ p: SIMD3<Float>, _ q: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        -> AlvrHeadPose {
        AlvrHeadPose(rotation: q, position: p)
    }

    /// An open left/right hand, palm down at `origin`, fingers along -Z.
    /// Every fingertip is far from the thumb and from its knuckles.
    private static func openHand(_ hand: AlvrHand, origin: SIMD3<Float> = .zero)
        -> [SIMD3<Float>] {
        let thumbSide: Float = hand == .left ? 1 : -1
        var joints = [SIMD3<Float>](repeating: .zero, count: 26)
        joints[0] = origin                                   // palm
        joints[1] = origin + SIMD3(0, 0, 0.05)               // wrist
        for (index, joint) in (2...5).enumerated() {          // thumb out sideways
            joints[joint] = origin + SIMD3(thumbSide * (0.03 + 0.02 * Float(index)), 0, 0.02)
        }
        for finger in 0..<4 {
            let x = thumbSide * (0.02 - 0.015 * Float(finger))
            let first = 6 + finger * 5
            for segment in 0..<5 {
                joints[first + segment] = origin + SIMD3(x, 0, 0.03 - 0.025 * Float(segment))
            }
        }
        return joints
    }

    private static func skeleton(_ positions: [SIMD3<Float>]) -> AlvrHandSkeleton {
        AlvrHandSkeleton(joints: positions.map { pose($0) })!
    }

    private static func curl(_ positions: inout [SIMD3<Float>], finger: Int) {
        let first = 6 + finger * 5
        positions[first + 4] = (positions[first] + positions[first + 1]) / 2
    }

    private static func trackingBody(timestamp: (UInt64, UInt32) = (5, 6),
                                     motions: [(UInt64, [Float])],
                                     skeletons: [AlvrHandSkeleton?]) -> Data {
        var body = Data()
        le(timestamp.0, &body)
        le(timestamp.1, &body)
        le(UInt64(motions.count), &body)
        for (id, values) in motions {
            le(id, &body)
            for value in values { f32(value, &body) }
        }
        for skeleton in skeletons {
            guard let skeleton else { body.append(0); continue }
            body.append(1)
            for joint in skeleton.joints {
                for value in [joint.orientationX, joint.orientationY, joint.orientationZ,
                              joint.orientationW, joint.positionX, joint.positionY,
                              joint.positionZ] { f32(value, &body) }
            }
        }
        // FaceData: two absent eye gazes and three absent expression vectors.
        body.append(contentsOf: [0, 0, 0, 0, 0])
        return body
    }

    private static func datagram(_ body: Data, index: UInt32, shardCount: UInt32,
                                 shard: UInt32) -> [UInt8] {
        var bytes = [UInt8]()
        func be<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
        }
        be(UInt32(18 + body.count - 4))
        be(UInt16(0))
        be(index)
        be(shardCount)
        be(shard)
        bytes.append(contentsOf: body)
        return bytes
    }

    private static let leftID: UInt64 = 0xe521_d8da_be2d_07a2
    private static let rightID: UInt64 = 0xf6b8_1330_eb3d_bdd8
    private static let headID: UInt64 = 0x5b90_853d_c920_2538

    // MARK: packet decoding

    func testDecodesFullTrackingPacketWithHandSkeleton() throws {
        let left = Self.skeleton(Self.openHand(.left, origin: SIMD3(-0.2, 1.1, -0.3)))
        let body = Self.trackingBody(
            motions: [
                (Self.headID, [0, 0, 0, 1, 0, 1.6, 0, 0, 0, 0, 0, 0, 0]),
                (Self.leftID, [0, 0, 0, 1, -0.2, 1.1, -0.3, 0, 0, 0, 0, 0, 0]),
                (Self.rightID, [0, 0, 0, 1, 0.2, 1.1, -0.3, 1, 2, 3, 4, 5, 6]),
            ],
            skeletons: [left, nil])
        let sample = try AlvrTrackingDecoder.decode([UInt8](body))
        XCTAssertEqual(sample.timestampNanoseconds, 5_000_000_006)
        XCTAssertEqual(sample.headPose?.positionY, 1.6)
        XCTAssertEqual(sample.leftSkeleton, left)
        XCTAssertNil(sample.rightSkeleton)
        XCTAssertEqual(sample.rightHand?.angularVelocityZ, 6)
        XCTAssertEqual(sample.leftSkeleton?[.indexTip].positionZ ?? 0, -0.37, accuracy: 1e-6)
        // 26 joints x 28 bytes, as ALVR's bincode writes them.
        XCTAssertEqual(body.count, 12 + 8 + 3 * 60 + (1 + 728) + 1 + 5)
    }

    func testRejectsTruncatedSkeleton() {
        let left = Self.skeleton(Self.openHand(.left))
        let body = Self.trackingBody(motions: [], skeletons: [left, nil])
        XCTAssertThrowsError(try AlvrTrackingDecoder.decode([UInt8](body.prefix(400))))
    }

    func testReassemblesShardedTrackingPackets() throws {
        let body = Self.trackingBody(
            motions: [(Self.headID, [0, 0, 0, 1, 0, 1.6, 0, 0, 0, 0, 0, 0, 0])],
            skeletons: [Self.skeleton(Self.openHand(.left)), Self.skeleton(Self.openHand(.right))])
        let cut = 1_000
        let first = body.prefix(cut), second = body.dropFirst(cut)
        var reassembler = AlvrTrackingReassembler()
        // Out of order within one packet still completes.
        XCTAssertNil(reassembler.add(Self.datagram(Data(second), index: 9, shardCount: 2, shard: 1)))
        XCTAssertEqual(reassembler.add(Self.datagram(Data(first), index: 9, shardCount: 2, shard: 0)),
                       [UInt8](body))
        // An incomplete packet is dropped when a newer one starts; a late
        // shard of the older one is ignored.
        XCTAssertNil(reassembler.add(Self.datagram(Data(first), index: 10, shardCount: 2, shard: 0)))
        XCTAssertNil(reassembler.add(Self.datagram(Data(first), index: 11, shardCount: 2, shard: 0)))
        XCTAssertNil(reassembler.add(Self.datagram(Data(second), index: 10, shardCount: 2, shard: 1)))
        XCTAssertEqual(reassembler.add(Self.datagram(Data(second), index: 11, shardCount: 2, shard: 1)),
                       [UInt8](body))
        // Single-shard packets pass straight through.
        XCTAssertEqual(reassembler.add(Self.datagram(body, index: 12, shardCount: 1, shard: 0)),
                       [UInt8](body))
    }

    func testSenderJoinsUDPShardsIntoOneTrackingSample() throws {
        let peer = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        func bind(_ fd: Int32, _ address: inout sockaddr_in) -> Int32 {
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(bind(peer, &address), 0)
        func port(_ fd: Int32) -> UInt16 {
            var bound = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &size) }
            }
            return UInt16(bigEndian: bound.sin_port)
        }
        let sender = try AlvrVideoStreamSender(host: "127.0.0.1", remotePort: port(peer),
                                               localPort: 0)
        let received = expectation(description: "tracking sample")
        let sampleBox = SampleBox()
        sender.onTrackingSample = { sample in
            sampleBox.sample = sample
            received.fulfill()
        }
        // Find the sender's ephemeral port: it is the source of a video shard.
        sender.send(annexB: Data([0, 0, 0, 1, 0x65]), timestampNanoseconds: 1, isIDR: true)
        var source = sockaddr_in()
        var sourceSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        var buffer = [UInt8](repeating: 0, count: 2_048)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let count = withUnsafeMutablePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(peer, &buffer, buffer.count, 0, $0, &sourceSize)
            }
        }
        XCTAssertGreaterThan(count, 0)

        let right = Self.skeleton(Self.openHand(.right, origin: SIMD3(0.2, 1, -0.3)))
        let body = Self.trackingBody(
            motions: [(Self.rightID, [0, 0, 0, 1, 0.2, 1, -0.3, 0, 0, 0, 0, 0, 0])],
            skeletons: [nil, right])
        for (index, part) in [body.prefix(700), body.dropFirst(700)].enumerated() {
            let shard = Self.datagram(Data(part), index: 3, shardCount: 2, shard: UInt32(index))
            _ = withUnsafePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(peer, shard, shard.count, 0, $0, sourceSize)
                }
            }
        }
        wait(for: [received], timeout: 2)
        XCTAssertEqual(sampleBox.sample?.rightSkeleton, right)
        XCTAssertNil(sampleBox.sample?.leftSkeleton)
        sender.close()
    }

    private final class SampleBox: @unchecked Sendable { var sample: AlvrTrackingSample? }

    // MARK: pose conversion

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-5,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(a, b), accuracy, "\(a) vs \(b)", file: file, line: line)
    }

    func testControllerGripUndoesTheALVRClientOffset() {
        // A Meta grip pose with some yaw and motion, then what the ALVR
        // client sends: grip * get_controller_offset (Quest: 5 mm, -15° X).
        let grip = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3(0.3, 1, 0.2)))
        let gripPosition = SIMD3<Float>(0.1, 1.2, -0.4)
        let angular = SIMD3<Float>(0.5, -1, 2)
        let gripLinear = SIMD3<Float>(0.3, 0.1, -0.2)
        for hand in [AlvrHand.left, .right] {
            let offset = AlvrGripPose.alvrClientOffset(hand)
            let reportedRotation = grip * offset.rotation
            let lever = grip.act(offset.position)
            let reported = AlvrControllerMotion(
                pose: AlvrHeadPose(rotation: reportedRotation, position: gripPosition + lever),
                linearVelocityX: gripLinear.x + simd_cross(angular, lever).x,
                linearVelocityY: gripLinear.y + simd_cross(angular, lever).y,
                linearVelocityZ: gripLinear.z + simd_cross(angular, lever).z,
                angularVelocityX: angular.x, angularVelocityY: angular.y,
                angularVelocityZ: angular.z)
            let recovered = AlvrGripPose.controllerGrip(fromALVR: reported, hand: hand)
            assertClose(recovered.pose.position, gripPosition)
            XCTAssertGreaterThan(abs(simd_dot(recovered.pose.rotation.vector, grip.vector)), 0.99999)
            assertClose(SIMD3(recovered.linearVelocityX, recovered.linearVelocityY,
                              recovered.linearVelocityZ), gripLinear)
            // Evidence for the bug this fixes: ALVR's pose is pitched 15°.
            let angle = 2 * acos(min(1, abs(simd_dot(reportedRotation.vector, grip.vector))))
            XCTAssertEqual(angle * 180 / .pi, 15, accuracy: 0.01)
        }
        // The right offset mirrors x only.
        XCTAssertEqual(AlvrGripPose.alvrClientOffset(.right).position.x, 0.005)
    }

    func testHandGripFollowsOpenXRGripAxes() {
        // Palm down, fingers forward (-Z): palm +Y up is the back of the hand.
        let palm = Self.pose(SIMD3(0, 1, -0.3))
        var joints = Self.openHand(.right).map { Self.pose($0) }
        joints[0] = palm
        let right = AlvrGripPose.handGrip(from: AlvrHandSkeleton(joints: joints)!, hand: .right)
        let rq = right.pose.rotation
        // Right: +X into the palm (toward the back of the hand = up), -Z from
        // little finger to thumb (the right thumb is to the left: -X).
        assertClose(rq.act(SIMD3(1, 0, 0)), SIMD3(0, 1, 0))
        assertClose(rq.act(SIMD3(0, 0, -1)), SIMD3(-1, 0, 0))
        // The grip sits 2.5 cm on the palm side.
        assertClose(right.pose.position, SIMD3(0, 1 - 0.025, -0.3))

        joints = Self.openHand(.left).map { Self.pose($0) }
        joints[0] = palm
        let left = AlvrGripPose.handGrip(from: AlvrHandSkeleton(joints: joints)!, hand: .left)
        let lq = left.pose.rotation
        // Left: +X away from the palm (down), -Z toward the thumb (+X).
        assertClose(lq.act(SIMD3(1, 0, 0)), SIMD3(0, -1, 0))
        assertClose(lq.act(SIMD3(0, 0, -1)), SIMD3(1, 0, 0))
        XCTAssertEqual(left.linearVelocityX, 0)
    }

    // MARK: gestures

    func testPinchDrivesTriggerAfterActivationDelay() {
        var recognizer = AlvrHandGestureRecognizer(hand: .left)
        var hand = Self.openHand(.left)
        let open = recognizer.buttons(for: Self.skeleton(hand), nowMilliseconds: 0)
        XCTAssertEqual(open[AlvrTouchPath.leftTriggerValue], .scalar(0))
        XCTAssertEqual(open[AlvrTouchPath.leftTriggerTouch], .binary(false))
        XCTAssertEqual(open[AlvrTouchPath.leftSqueezeValue], .scalar(0))
        XCTAssertEqual(open[AlvrTouchPath.leftThumbstickTouch], .binary(false))

        hand[5] = hand[10] // thumb tip on index tip
        let entering = recognizer.buttons(for: Self.skeleton(hand), nowMilliseconds: 1_000)
        XCTAssertEqual(entering[AlvrTouchPath.leftTriggerValue], .scalar(0), "50 ms activation delay")
        let pinched = recognizer.buttons(for: Self.skeleton(hand), nowMilliseconds: 1_060)
        XCTAssertEqual(pinched[AlvrTouchPath.leftTriggerValue], .scalar(1))
        XCTAssertEqual(pinched[AlvrTouchPath.leftTriggerTouch], .binary(true))
        XCTAssertEqual(pinched[AlvrTouchPath.leftYClick], .binary(false))

        // Opening the pinch releases at once (ALVR: touch = active && the
        // current distance), but the gesture stays active for 100 ms, so a
        // one-frame tracking dropout does not need a new activation delay.
        let released = Self.openHand(.left)
        let dropout = recognizer.buttons(for: Self.skeleton(released), nowMilliseconds: 1_100)
        XCTAssertEqual(dropout[AlvrTouchPath.leftTriggerTouch], .binary(false))
        XCTAssertEqual(dropout[AlvrTouchPath.leftTriggerValue], .scalar(0))
        let back = recognizer.buttons(for: Self.skeleton(hand), nowMilliseconds: 1_120)
        XCTAssertEqual(back[AlvrTouchPath.leftTriggerValue], .scalar(1), "no new activation delay")
        _ = recognizer.buttons(for: Self.skeleton(released), nowMilliseconds: 1_200)
        _ = recognizer.buttons(for: Self.skeleton(released), nowMilliseconds: 1_320)
        // Deactivated now: re-entering needs the activation delay again.
        let again = recognizer.buttons(for: Self.skeleton(hand), nowMilliseconds: 1_500)
        XCTAssertEqual(again[AlvrTouchPath.leftTriggerValue], .scalar(0))
        let on = recognizer.buttons(for: Self.skeleton(hand), nowMilliseconds: 1_560)
        XCTAssertEqual(on[AlvrTouchPath.leftTriggerValue], .scalar(1))
    }

    func testFingerPinchesMapToFaceButtonsPerHand() {
        for (hand, middle, ring) in [
            (AlvrHand.left, AlvrTouchPath.leftYClick, AlvrTouchPath.leftXClick),
            (.right, AlvrTouchPath.rightBClick, AlvrTouchPath.rightAClick),
        ] {
            for (tip, expected, other) in [(15, middle, ring), (20, ring, middle)] {
                var recognizer = AlvrHandGestureRecognizer(hand: hand)
                var joints = Self.openHand(hand)
                joints[5] = joints[tip]
                _ = recognizer.buttons(for: Self.skeleton(joints), nowMilliseconds: 0)
                let values = recognizer.buttons(for: Self.skeleton(joints), nowMilliseconds: 60)
                XCTAssertEqual(values[expected], .binary(true), "\(hand) tip \(tip)")
                XCTAssertEqual(values[other], .binary(false))
            }
        }
        var left = AlvrHandGestureRecognizer(hand: .left)
        var joints = Self.openHand(.left)
        joints[5] = joints[25]
        _ = left.buttons(for: Self.skeleton(joints), nowMilliseconds: 0)
        XCTAssertEqual(left.buttons(for: Self.skeleton(joints), nowMilliseconds: 60)[
            AlvrTouchPath.leftMenuClick], .binary(true))
    }

    func testFistDrivesSqueezeAndThumbOnIndexDrivesThumbstick() {
        var recognizer = AlvrHandGestureRecognizer(hand: .left)
        var joints = Self.openHand(.left)
        for finger in 0..<4 { Self.curl(&joints, finger: finger) }
        let fist = recognizer.buttons(for: Self.skeleton(joints), nowMilliseconds: 0)
        XCTAssertEqual(fist[AlvrTouchPath.leftSqueezeValue], .scalar(1))
        XCTAssertEqual(fist[AlvrTouchPath.leftThumbstickTouch], .binary(false))

        // Thumb tip 8 mm along the index's +Y (left side) from the middle of
        // its intermediate and distal joints: stick x = 0.8.
        let center = (joints[8] + joints[9]) / 2
        joints[5] = center + SIMD3(0, 0.008, 0)
        let stick = recognizer.buttons(for: Self.skeleton(joints), nowMilliseconds: 10)
        XCTAssertEqual(stick[AlvrTouchPath.leftThumbstickTouch], .binary(true))
        guard case .scalar(let x) = stick[AlvrTouchPath.leftThumbstickX] else {
            return XCTFail("no thumbstick x")
        }
        XCTAssertEqual(x, 0.8, accuracy: 1e-4)
        XCTAssertEqual(stick[AlvrTouchPath.leftThumbstickY], .scalar(0), "inside the dead zone")
    }

    // MARK: router

    private final class Recorder: @unchecked Sendable {
        var motions: [(AlvrHand, AlvrControllerMotion)] = []
        var masks: [UInt32] = []
        var skeletons: [(AlvrHand, AlvrHandSkeleton?)] = []
        var buttons: [UInt64: AlvrButtonValue] = [:]
        var buttonBatches: [[AlvrButtonEntry]] = []
        var profiles: [(UInt64, UInt64)] = []
        var modes: [(AlvrHand, Bool)] = []

        func outputs() -> HandTrackingInputRouter.Outputs {
            var outputs = HandTrackingInputRouter.Outputs()
            outputs.controllerMotion = { _, hand, motion in self.motions.append((hand, motion)) }
            outputs.controllerMask = { _, mask in self.masks.append(mask) }
            outputs.handSkeleton = { _, hand, skeleton in self.skeletons.append((hand, skeleton)) }
            outputs.buttons = { entries in
                self.buttonBatches.append(entries)
                for entry in entries { self.buttons[entry.pathID] = entry.value }
            }
            outputs.interactionProfile = { self.profiles.append(($0, $1)) }
            outputs.modeChanged = { self.modes.append(($0, $1)) }
            return outputs
        }
    }

    private static func sample(left: AlvrControllerMotion? = nil, right: AlvrControllerMotion? = nil,
                               leftSkeleton: AlvrHandSkeleton? = nil,
                               rightSkeleton: AlvrHandSkeleton? = nil) -> AlvrTrackingSample {
        AlvrTrackingSample(timestampNanoseconds: 1, headPose: nil, leftHand: left,
                           rightHand: right, leftSkeleton: leftSkeleton,
                           rightSkeleton: rightSkeleton)
    }

    private static func motion(_ p: SIMD3<Float>) -> AlvrControllerMotion {
        AlvrControllerMotion(pose: pose(p), linearVelocityX: 0, linearVelocityY: 0,
                             linearVelocityZ: 0, angularVelocityX: 0, angularVelocityY: 0,
                             angularVelocityZ: 0)
    }

    func testRouterSwitchesBetweenControllerAndHandTrackingMidSession() {
        let recorder = Recorder()
        var now = 0.0
        let router = HandTrackingInputRouter(handTrackingEnabled: true,
                                             outputs: recorder.outputs(), clock: { now })
        let touch = AlvrTouchPath.questTouchProfileID

        // Controllers: the client's profile and buttons pass through, the
        // pose loses ALVR's offset.
        router.handleClientInteractionProfile(deviceID: Self.leftID, profileID: touch)
        router.handleClientButtons([
            AlvrButtonEntry(pathID: AlvrTouchPath.leftTriggerValue, value: .scalar(0.7)),
            AlvrButtonEntry(pathID: AlvrTouchPath.leftThumbrestTouch, value: .binary(true)),
        ])
        router.handleTracking(Self.sample(left: Self.motion(SIMD3(-0.2, 1, -0.3))))
        XCTAssertEqual(recorder.profiles.count, 1)
        XCTAssertEqual(recorder.buttons[AlvrTouchPath.leftTriggerValue], .scalar(0.7))
        XCTAssertEqual(recorder.masks.last, 1)
        XCTAssertNotEqual(recorder.motions.last?.1.pose.orientationW, 1, "ALVR pitch removed")

        // The controller is put down: the hand skeleton takes over.
        var joints = Self.openHand(.left, origin: SIMD3(-0.2, 1, -0.3))
        let palmMotion = Self.motion(joints[0])
        now = 100
        router.handleTracking(Self.sample(left: palmMotion, leftSkeleton: Self.skeleton(joints)))
        XCTAssertEqual(recorder.modes.last?.0, .left)
        XCTAssertEqual(recorder.modes.last?.1, true)
        XCTAssertEqual(recorder.profiles.count, 1, "already Touch; no profile change event")
        XCTAssertEqual(recorder.skeletons.last?.1, Self.skeleton(joints))
        XCTAssertEqual(recorder.motions.last?.1,
                       AlvrGripPose.handGrip(from: Self.skeleton(joints), hand: .left))
        XCTAssertEqual(recorder.buttons[AlvrTouchPath.leftTriggerValue], .scalar(0),
                       "the held controller trigger is released")
        XCTAssertEqual(recorder.buttons[AlvrTouchPath.leftThumbrestTouch], .binary(false))
        XCTAssertEqual(recorder.masks.last, 1)

        // Client buttons for a hand-tracked hand are held back; the other
        // hand's still pass.
        router.handleClientButtons([
            AlvrButtonEntry(pathID: AlvrTouchPath.leftTriggerValue, value: .scalar(0.2)),
            AlvrButtonEntry(pathID: AlvrTouchPath.rightAClick, value: .binary(true)),
        ])
        XCTAssertEqual(recorder.buttons[AlvrTouchPath.leftTriggerValue], .scalar(0))
        XCTAssertEqual(recorder.buttons[AlvrTouchPath.rightAClick], .binary(true))

        // A pinch fires the trigger.
        joints[5] = joints[10]
        router.handleTracking(Self.sample(left: palmMotion, leftSkeleton: Self.skeleton(joints)))
        now = 200
        let batches = recorder.buttonBatches.count
        router.handleTracking(Self.sample(left: palmMotion, leftSkeleton: Self.skeleton(joints)))
        XCTAssertEqual(recorder.buttons[AlvrTouchPath.leftTriggerValue], .scalar(1))
        router.handleTracking(Self.sample(left: palmMotion, leftSkeleton: Self.skeleton(joints)))
        XCTAssertEqual(recorder.buttonBatches.count, batches + 1, "unchanged values are not resent")

        // The controller is picked up again: skeleton cleared, client values back.
        router.handleTracking(Self.sample(left: Self.motion(SIMD3(-0.2, 1, -0.3))))
        XCTAssertEqual(recorder.modes.last?.1, false)
        XCTAssertNil(recorder.skeletons.last?.1 ?? nil)
        XCTAssertEqual(recorder.buttons[AlvrTouchPath.leftTriggerValue], .scalar(0.2))
        XCTAssertEqual(recorder.buttons[AlvrTouchPath.leftThumbrestTouch], .binary(true))
        XCTAssertEqual(recorder.profiles.count, 1)
    }

    func testRouterPublishesTouchProfileWhenHandsStartTheSession() {
        let recorder = Recorder()
        let router = HandTrackingInputRouter(handTrackingEnabled: true,
                                             outputs: recorder.outputs(), clock: { 0 })
        let joints = Self.openHand(.right)
        router.handleTracking(Self.sample(right: Self.motion(joints[0]),
                                          rightSkeleton: Self.skeleton(joints)))
        XCTAssertEqual(recorder.profiles.first?.0, Self.rightID)
        XCTAssertEqual(recorder.profiles.first?.1, AlvrTouchPath.questTouchProfileID)
        XCTAssertEqual(recorder.masks.last, 2)
        // Hands lost and no controller: untracked, skeleton cleared.
        router.handleTracking(Self.sample())
        XCTAssertEqual(recorder.masks.last, 0)
        XCTAssertEqual(recorder.skeletons.last?.0, .right)
        XCTAssertNil(recorder.skeletons.last?.1 ?? nil)
    }

    func testRouterWithHandTrackingOffNeverUsesThePalmPoseAsAGrip() {
        let recorder = Recorder()
        let router = HandTrackingInputRouter(handTrackingEnabled: false,
                                             outputs: recorder.outputs(), clock: { 0 })
        let joints = Self.openHand(.left)
        router.handleTracking(Self.sample(left: Self.motion(joints[0]),
                                          leftSkeleton: Self.skeleton(joints)))
        XCTAssertTrue(recorder.motions.isEmpty)
        XCTAssertTrue(recorder.skeletons.isEmpty)
        XCTAssertEqual(recorder.masks.last, 0)
    }

    // MARK: runtime wire format

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[data.startIndex + offset + $1]) << UInt32($1 * 8) }
    }

    private func u64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(u32(data, offset)) | UInt64(u32(data, offset + 4)) << 32
    }

    func testHandSkeletonPayloadLayout() throws {
        let skeleton = Self.skeleton(Self.openHand(.left, origin: SIMD3(1, 2, 3)))
        let payload = try XCTUnwrap(RuntimeLink.handSkeletonPayload(
            timestampNanoseconds: 42, hand: .right, skeleton: skeleton))
        XCTAssertEqual(payload.count, RuntimeLink.handSkeletonPayloadLength)
        XCTAssertEqual(u64(payload, 0), 42)
        XCTAssertEqual(u32(payload, 8), 1)
        XCTAssertEqual(u32(payload, 12), (1 << 26) - 1)
        // Joint 0: identity orientation, position, radius.
        XCTAssertEqual(Float(bitPattern: u32(payload, 16 + 12)), 1)
        XCTAssertEqual(Float(bitPattern: u32(payload, 16 + 16)), 1)
        XCTAssertEqual(Float(bitPattern: u32(payload, 16 + 28)),
                       AlvrHandSkeleton.jointRadiiMeters[0])
        let lost = try XCTUnwrap(RuntimeLink.handSkeletonPayload(
            timestampNanoseconds: 43, hand: .left, skeleton: nil))
        XCTAssertEqual(lost.count, RuntimeLink.handSkeletonPayloadLength)
        XCTAssertEqual(u32(lost, 12), 0)
    }

    func testControlFileAdvertisesHandTrackingFeature() {
        let token = String(repeating: "a", count: 32)
        XCTAssertEqual(RuntimeLink.controlFileLine(
            port: 7, token: token, recommendedViewSize: try! PerEyeResolution(width: 1152, height: 1216),
            features: [RuntimeLink.handTrackingFeature]),
            "7 \(token) 1152 1216 hand_tracking\n")
        XCTAssertEqual(RuntimeLink.controlFileLine(
            port: 7, token: token, recommendedViewSize: nil, features: ["hand_tracking"]),
            "7 \(token) hand_tracking\n")
        XCTAssertEqual(RuntimeLink.controlFileLine(port: 7, token: token, recommendedViewSize: nil),
                       "7 \(token)\n")
    }

    /// The emulated buttons only work if these IDs are the ones the runtime
    /// binds for oculus/touch_controller.
    func testTouchPathIDsMatchRuntimeBindings() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("runtime/pe/input.cpp"),
                                encoding: .utf8)
        let regex = try NSRegularExpression(
            pattern: #"\{"(/user/hand/(left|right)/input/[a-z/]+)", [01], BindingKind::k[A-Za-z0-9]+, (0x[0-9a-f]+)ULL"#)
        var runtime: [String: UInt64] = [:]
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let path = String(source[Range(match.range(at: 1), in: source)!])
            let hex = String(source[Range(match.range(at: 3), in: source)!]).dropFirst(2)
            runtime[path] = UInt64(hex, radix: 16)
        }
        typealias P = AlvrTouchPath
        let expected: [String: UInt64] = [
            "/user/hand/left/input/x/click": P.leftXClick, "/user/hand/left/input/x/touch": P.leftXTouch,
            "/user/hand/left/input/y/click": P.leftYClick, "/user/hand/left/input/y/touch": P.leftYTouch,
            "/user/hand/left/input/menu/click": P.leftMenuClick,
            "/user/hand/left/input/squeeze/value": P.leftSqueezeValue,
            "/user/hand/left/input/trigger/value": P.leftTriggerValue,
            "/user/hand/left/input/trigger/touch": P.leftTriggerTouch,
            "/user/hand/left/input/thumbstick/x": P.leftThumbstickX,
            "/user/hand/left/input/thumbstick/y": P.leftThumbstickY,
            "/user/hand/left/input/thumbstick/click": P.leftThumbstickClick,
            "/user/hand/left/input/thumbstick/touch": P.leftThumbstickTouch,
            "/user/hand/left/input/thumbrest/touch": P.leftThumbrestTouch,
            "/user/hand/right/input/a/click": P.rightAClick, "/user/hand/right/input/a/touch": P.rightATouch,
            "/user/hand/right/input/b/click": P.rightBClick, "/user/hand/right/input/b/touch": P.rightBTouch,
            "/user/hand/right/input/squeeze/value": P.rightSqueezeValue,
            "/user/hand/right/input/trigger/value": P.rightTriggerValue,
            "/user/hand/right/input/trigger/touch": P.rightTriggerTouch,
            "/user/hand/right/input/thumbstick/x": P.rightThumbstickX,
            "/user/hand/right/input/thumbstick/y": P.rightThumbstickY,
            "/user/hand/right/input/thumbstick/click": P.rightThumbstickClick,
            "/user/hand/right/input/thumbstick/touch": P.rightThumbstickTouch,
            "/user/hand/right/input/thumbrest/touch": P.rightThumbrestTouch,
        ]
        for (path, id) in expected {
            XCTAssertEqual(runtime[path], id, path)
        }
        XCTAssertEqual(P.rightSystemClick, 0x1972_9bd9_7073_d474)
    }
}
