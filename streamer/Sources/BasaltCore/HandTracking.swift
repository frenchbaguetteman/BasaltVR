import Foundation
import simd

/// One Quest hand skeleton as the ALVR v20 client sends it: 26 joint poses
/// in XR_EXT_hand_tracking order (0 palm, 1 wrist, 2-5 thumb metacarpal to
/// tip, 6-10 index, 11-15 middle, 16-20 ring, 21-25 little), located in the
/// Quest STAGE space like the controllers. ALVR sends poses only (no radius,
/// no velocity, no per-joint validity), only while the hand is tracked, and
/// not predicted: the client locates joints at its current time
/// (`client_openxr/src/interaction.rs`, v20.14.1).
public struct AlvrHandSkeleton: Equatable, Sendable {
    public static let jointCount = 26

    public enum Joint: Int, CaseIterable, Sendable {
        case palm = 0, wrist
        case thumbMetacarpal, thumbProximal, thumbDistal, thumbTip
        case indexMetacarpal, indexProximal, indexIntermediate, indexDistal, indexTip
        case middleMetacarpal, middleProximal, middleIntermediate, middleDistal, middleTip
        case ringMetacarpal, ringProximal, ringIntermediate, ringDistal, ringTip
        case littleMetacarpal, littleProximal, littleIntermediate, littleDistal, littleTip
    }

    /// Typical adult joint radii in meters, sent as XrHandJointLocationEXT
    /// radius because ALVR does not transmit them.
    public static let jointRadiiMeters: [Float] = [
        0.020, 0.020,                         // palm, wrist
        0.016, 0.011, 0.009, 0.008,           // thumb
        0.010, 0.010, 0.008, 0.007, 0.006,    // index
        0.010, 0.010, 0.008, 0.007, 0.006,    // middle
        0.009, 0.009, 0.008, 0.007, 0.006,    // ring
        0.008, 0.008, 0.007, 0.006, 0.005,    // little
    ]

    public let joints: [AlvrHeadPose]

    public init?(joints: [AlvrHeadPose]) {
        guard joints.count == Self.jointCount else { return nil }
        self.joints = joints
    }

    public subscript(_ joint: Joint) -> AlvrHeadPose { joints[joint.rawValue] }
}

// MARK: - Tracking packet

/// The complete ALVR v20 `Tracking` packet that Basalt uses: device motions
/// plus both hand skeletons (`alvr/packets/src/lib.rs`). Face data follows
/// the skeletons on the wire and is ignored.
public struct AlvrTrackingSample: Equatable, Sendable {
    public let timestampNanoseconds: UInt64
    public let headPose: AlvrHeadPose?
    /// Motions of `/user/hand/left|right`. Without ALVR's multimodal
    /// protocol a hand-tracked hand's motion is its raw palm pose with zero
    /// velocity (`client_core/src/lib.rs`), not a controller grip.
    public let leftHand: AlvrControllerMotion?
    public let rightHand: AlvrControllerMotion?
    public let leftSkeleton: AlvrHandSkeleton?
    public let rightSkeleton: AlvrHandSkeleton?

    public init(timestampNanoseconds: UInt64, headPose: AlvrHeadPose?,
                leftHand: AlvrControllerMotion?, rightHand: AlvrControllerMotion?,
                leftSkeleton: AlvrHandSkeleton?, rightSkeleton: AlvrHandSkeleton?) {
        self.timestampNanoseconds = timestampNanoseconds
        self.headPose = headPose
        self.leftHand = leftHand
        self.rightHand = rightHand
        self.leftSkeleton = leftSkeleton
        self.rightSkeleton = rightSkeleton
    }

    public func motion(_ hand: AlvrHand) -> AlvrControllerMotion? {
        hand == .left ? leftHand : rightHand
    }

    public func skeleton(_ hand: AlvrHand) -> AlvrHandSkeleton? {
        hand == .left ? leftSkeleton : rightSkeleton
    }
}

/// Decodes the bincode body of ALVR v20's `Tracking` (after the 18-byte
/// stream prefix, all shards concatenated): Duration, Vec<(u64,
/// DeviceMotion)>, then `[Option<[Pose; 26]>; 2]`. bincode 1 fixint
/// little-endian: Option is a u8 tag, Vec a u64 length, arrays unprefixed,
/// Pose is Quat(x, y, z, w) then Vec3.
public enum AlvrTrackingDecoder {
    static let headID: UInt64 = 0x5b90_853d_c920_2538
    static let deviceMotionSize = 8 + 13 * 4
    static let poseSize = 7 * 4
    static let skeletonSize = AlvrHandSkeleton.jointCount * poseSize

    public static func decode(_ body: [UInt8]) throws -> AlvrTrackingSample {
        var reader = ByteReader(body)
        let seconds = try reader.u64()
        let nanos = try reader.u32()
        guard nanos < 1_000_000_000 else { throw BasaltError("Invalid ALVR duration") }
        let (secondsNanos, overflow1) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (timestamp, overflow2) = secondsNanos.addingReportingOverflow(UInt64(nanos))
        guard !overflow1, !overflow2 else { throw BasaltError("ALVR duration overflow") }

        let count = try reader.u64()
        guard count <= 64 else { throw BasaltError("Too many ALVR device motions") }
        var head: AlvrHeadPose?
        var left: AlvrControllerMotion?
        var right: AlvrControllerMotion?
        for _ in 0..<count {
            let deviceID = try reader.u64()
            var values = [Float]()
            values.reserveCapacity(13)
            for _ in 0..<13 { values.append(try reader.f32()) }
            guard let pose = AlvrHeadPose(validating: values) else { continue }
            if deviceID == headID {
                head = pose
            } else if let hand = AlvrHand(alvrDeviceID: deviceID) {
                let motion = AlvrControllerMotion(
                    pose: pose,
                    linearVelocityX: values[7], linearVelocityY: values[8],
                    linearVelocityZ: values[9], angularVelocityX: values[10],
                    angularVelocityY: values[11], angularVelocityZ: values[12])
                if hand == .left { left = motion } else { right = motion }
            }
        }

        var skeletons: [AlvrHandSkeleton?] = []
        for _ in 0..<2 {
            switch try reader.u8() {
            case 0:
                skeletons.append(nil)
            case 1:
                var joints = [AlvrHeadPose]()
                joints.reserveCapacity(AlvrHandSkeleton.jointCount)
                var valid = true
                for _ in 0..<AlvrHandSkeleton.jointCount {
                    var values = [Float]()
                    for _ in 0..<7 { values.append(try reader.f32()) }
                    if let pose = AlvrHeadPose(validating: values) {
                        joints.append(pose)
                    } else {
                        valid = false
                    }
                }
                skeletons.append(valid ? AlvrHandSkeleton(joints: joints) : nil)
            default:
                throw BasaltError("Invalid ALVR hand skeleton option tag")
            }
        }
        return AlvrTrackingSample(
            timestampNanoseconds: timestamp, headPose: head,
            leftHand: left, rightHand: right,
            leftSkeleton: skeletons[0], rightSkeleton: skeletons[1])
    }
}

/// Joins the shards of ALVR tracking packets. A Tracking packet with both
/// hand skeletons (~1.7 KB) spans two Wi-Fi shards. Only the newest packet
/// is kept: an incomplete older one is dropped when a newer index arrives.
public struct AlvrTrackingReassembler: Sendable {
    static let maximumShards: UInt32 = 16
    private var packetIndex: UInt32?
    private var shardCount: UInt32 = 0
    private var shards: [UInt32: [UInt8]] = [:]

    public init() {}

    /// Feeds one stream-0 datagram (with its 18-byte prefix). Returns the
    /// concatenated body when the packet is complete.
    public mutating func add(_ datagram: [UInt8]) -> [UInt8]? {
        guard datagram.count >= 18 else { return nil }
        func bigEndian32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { ($0 << 8) | UInt32(datagram[offset + $1]) }
        }
        let index = bigEndian32(6)
        let count = bigEndian32(10)
        let shard = bigEndian32(14)
        guard count > 0, count <= Self.maximumShards, shard < count else { return nil }
        let body = Array(datagram[18...])
        if count == 1 {
            reset()
            return body
        }
        if packetIndex != index {
            // Wrapping comparison: ignore a late shard of an older packet.
            if let current = packetIndex, Int32(bitPattern: index &- current) < 0 {
                return nil
            }
            packetIndex = index
            shardCount = count
            shards.removeAll(keepingCapacity: true)
        }
        guard count == shardCount else { return nil }
        shards[shard] = body
        guard shards.count == Int(shardCount) else { return nil }
        var joined = [UInt8]()
        for position in 0..<shardCount { joined.append(contentsOf: shards[position]!) }
        reset()
        return joined
    }

    private mutating func reset() {
        packetIndex = nil
        shardCount = 0
        shards.removeAll(keepingCapacity: true)
    }
}

private struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw BasaltError("Truncated ALVR tracking packet") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u32() throws -> UInt32 { UInt32(try integer(4)) }
    mutating func u64() throws -> UInt64 { try integer(8) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    private mutating func integer(_ size: Int) throws -> UInt64 {
        guard offset + size <= bytes.count else {
            throw BasaltError("Truncated ALVR tracking packet")
        }
        var value: UInt64 = 0
        for index in 0..<size { value |= UInt64(bytes[offset + index]) << UInt64(index * 8) }
        offset += size
        return value
    }
}

extension AlvrHeadPose {
    /// The first seven values as a pose; nil unless finite with a usable
    /// quaternion. The quaternion is normalized.
    init?(validating values: [Float]) {
        guard values.count >= 7, values.prefix(7).allSatisfy(\.isFinite) else { return nil }
        let norm = (values[0] * values[0] + values[1] * values[1]
            + values[2] * values[2] + values[3] * values[3]).squareRoot()
        guard norm > 0.7, norm < 1.3 else { return nil }
        self.init(orientationX: values[0] / norm, orientationY: values[1] / norm,
                  orientationZ: values[2] / norm, orientationW: values[3] / norm,
                  positionX: values[4], positionY: values[5], positionZ: values[6])
    }

    init(rotation: simd_quatf, position: SIMD3<Float>) {
        let q = rotation.normalized
        self.init(orientationX: q.imag.x, orientationY: q.imag.y, orientationZ: q.imag.z,
                  orientationW: q.real, positionX: position.x, positionY: position.y,
                  positionZ: position.z)
    }

    var rotation: simd_quatf {
        simd_quatf(ix: orientationX, iy: orientationY, iz: orientationZ, r: orientationW)
    }

    var position: SIMD3<Float> { SIMD3(positionX, positionY, positionZ) }
}

// MARK: - Pose conversions

/// Which grip pose the runtime exposes for a Touch controller.
public enum ControllerGripPose: String, CaseIterable, Sendable {
    /// What the ALVR client reports: Meta's grip times ALVR's SteamVR grip
    /// offset (-15° pitch, 5 mm). The pose before hand-tracking support.
    case alvr
    /// Meta's OpenXR grip pose: ALVR's offset removed
    /// (`AlvrGripPose.controllerGrip(fromALVR:hand:)`).
    case meta
}

/// Converts what ALVR reports for a hand into the OpenXR grip pose that the
/// Basalt runtime exposes as `/input/grip/pose`.
public enum AlvrGripPose {
    /// The ALVR v20 client reports a Quest controller as Meta's grip pose
    /// times its own `get_controller_offset` (`client_openxr/src/
    /// interaction.rs`): 5 mm and a -15° pitch, chosen for ALVR's SteamVR
    /// driver, which then adds its own `[0, 0, -0.11]` offset. OpenXR games
    /// and OpenComposite expect Meta's grip and apply their own grip-to-
    /// SteamVR transform, so `ControllerGripPose.meta` removes the ALVR
    /// offset here.
    /// Quest 2/3/3S/Pro values; the right hand mirrors x.
    static func alvrClientOffset(_ hand: AlvrHand) -> (rotation: simd_quatf, position: SIMD3<Float>) {
        let rotation = simd_quatf(angle: -15 * .pi / 180, axis: SIMD3(1, 0, 0))
        let position = SIMD3<Float>(hand == .left ? -0.005 : 0.005, -0.005, 0)
        return (rotation, position)
    }

    /// Meta's grip pose and velocity from the ALVR-reported controller
    /// motion: grip = reported * offset⁻¹. Angular velocity is unchanged;
    /// the linear velocity moves from the offset origin back to the grip
    /// origin (v_grip = v - ω × r).
    public static func controllerGrip(fromALVR motion: AlvrControllerMotion,
                                      hand: AlvrHand) -> AlvrControllerMotion {
        let offset = alvrClientOffset(hand)
        let reportedRotation = motion.pose.rotation
        let gripRotation = (reportedRotation * offset.rotation.inverse).normalized
        let lever = gripRotation.act(offset.position)
        let gripPosition = motion.pose.position - lever
        let angular = SIMD3(motion.angularVelocityX, motion.angularVelocityY,
                            motion.angularVelocityZ)
        let linear = SIMD3(motion.linearVelocityX, motion.linearVelocityY,
                           motion.linearVelocityZ) - simd_cross(angular, lever)
        return AlvrControllerMotion(
            pose: AlvrHeadPose(rotation: gripRotation, position: gripPosition),
            linearVelocityX: linear.x, linearVelocityY: linear.y, linearVelocityZ: linear.z,
            angularVelocityX: angular.x, angularVelocityY: angular.y,
            angularVelocityZ: angular.z)
    }

    /// Grip axes in the XR_EXT_hand_tracking palm frame (+Y out of the back
    /// of the hand, -Z toward the fingers, same convention for both hands).
    /// OpenXR grip: +X normal to the palm (away from the left palm, into the
    /// right palm), -Z along the curled-finger tube from little finger to
    /// thumb. Right: X=+Y_palm, Y=+Z_palm, Z=+X_palm; left: X=-Y_palm,
    /// Y=+Z_palm, Z=-X_palm.
    static func palmToGripRotation(_ hand: AlvrHand) -> simd_quatf {
        hand == .right
            ? simd_quatf(ix: 0.5, iy: 0.5, iz: 0.5, r: 0.5)
            : simd_quatf(ix: 0.5, iy: -0.5, iz: -0.5, r: 0.5)
    }

    /// The grip origin sits in front of the palm (the curled-finger tube),
    /// not at the palm joint inside the hand.
    static let palmToGripVolarMeters: Float = 0.025

    /// An emulated controller motion for a hand-tracked hand: the grip pose
    /// derived from the palm joint, with zero velocity like ALVR's own
    /// hand motion (the runtime does not extrapolate it).
    public static func handGrip(from skeleton: AlvrHandSkeleton,
                                hand: AlvrHand) -> AlvrControllerMotion {
        let palm = skeleton[.palm]
        let rotation = (palm.rotation * palmToGripRotation(hand)).normalized
        let position = palm.position
            + palm.rotation.act(SIMD3(0, -palmToGripVolarMeters, 0))
        return AlvrControllerMotion(
            pose: AlvrHeadPose(rotation: rotation, position: position),
            linearVelocityX: 0, linearVelocityY: 0, linearVelocityZ: 0,
            angularVelocityX: 0, angularVelocityY: 0, angularVelocityZ: 0)
    }
}

// MARK: - Touch controller paths

/// ALVR's hashed `/user/hand/*/input/*` path IDs for the Quest Touch
/// profile, as bound in runtime/pe/input.cpp (`kTouchSources`).
public enum AlvrTouchPath {
    public static let questTouchProfileID: UInt64 = 0x0812_fd85_c843_84a6

    public static let leftXClick: UInt64 = 0xb1a1_3c48_5685_e33c
    public static let leftXTouch: UInt64 = 0xc3d4_7643_2e89_d9dd
    public static let leftYClick: UInt64 = 0x5214_96d2_3e3e_9883
    public static let leftYTouch: UInt64 = 0x117d_0816_b380_e1f2
    public static let leftMenuClick: UInt64 = 0x6268_a669_e87c_f910
    public static let leftSqueezeValue: UInt64 = 0x01f1_b9c6_8980_4b82
    public static let leftTriggerValue: UInt64 = 0x0b66_bbe3_dc2d_c49f
    public static let leftTriggerTouch: UInt64 = 0x4fa5_7f59_dbae_033a
    public static let leftThumbstickX: UInt64 = 0xc3d7_09ed_0d79_4ea1
    public static let leftThumbstickY: UInt64 = 0xcb7d_9287_0626_3554
    public static let leftThumbstickClick: UInt64 = 0xdfc8_a612_73cf_2569
    public static let leftThumbstickTouch: UInt64 = 0x0966_df80_f498_9bfc
    public static let leftThumbrestTouch: UInt64 = 0x3ce1_c9ed_4d12_f3c2

    public static let rightAClick: UInt64 = 0xc72a_0ba6_ca52_fba7
    public static let rightATouch: UInt64 = 0x07ae_dc78_fdf1_bf2a
    public static let rightBClick: UInt64 = 0x9550_4746_6e34_669b
    public static let rightBTouch: UInt64 = 0xdd83_23ca_a5e4_8729
    public static let rightSystemClick: UInt64 = 0x1972_9bd9_7073_d474
    public static let rightSqueezeValue: UInt64 = 0xdd59_35cc_0051_36f1
    public static let rightTriggerValue: UInt64 = 0xede7_e982_d5ee_df21
    public static let rightTriggerTouch: UInt64 = 0xe0a7_e848_dde3_40b0
    public static let rightThumbstickX: UInt64 = 0xd7c2_3648_f060_c6df
    public static let rightThumbstickY: UInt64 = 0xcee8_c338_e02e_0131
    public static let rightThumbstickClick: UInt64 = 0x00ac_9a92_f445_3d61
    public static let rightThumbstickTouch: UInt64 = 0xef43_fe49_dfc8_7556
    public static let rightThumbrestTouch: UInt64 = 0x947e_5a8f_8780_c92d

    /// Scalar paths; the rest are binary.
    static let scalarPaths: Set<UInt64> = [
        leftSqueezeValue, leftTriggerValue, leftThumbstickX, leftThumbstickY,
        rightSqueezeValue, rightTriggerValue, rightThumbstickX, rightThumbstickY,
    ]

    /// Every Touch input of one hand. While that hand is hand-tracked the
    /// emulation owns all of them; the client's values return afterwards.
    public static func paths(_ hand: AlvrHand) -> [UInt64] {
        hand == .left
            ? [leftXClick, leftXTouch, leftYClick, leftYTouch, leftMenuClick,
               leftSqueezeValue, leftTriggerValue, leftTriggerTouch, leftThumbstickX,
               leftThumbstickY, leftThumbstickClick, leftThumbstickTouch, leftThumbrestTouch]
            : [rightAClick, rightATouch, rightBClick, rightBTouch, rightSystemClick,
               rightSqueezeValue, rightTriggerValue, rightTriggerTouch, rightThumbstickX,
               rightThumbstickY, rightThumbstickClick, rightThumbstickTouch,
               rightThumbrestTouch]
    }

    static func hand(of pathID: UInt64) -> AlvrHand? {
        if paths(.left).contains(pathID) { return .left }
        if paths(.right).contains(pathID) { return .right }
        return nil
    }

    static func released(_ pathID: UInt64) -> AlvrButtonValue {
        scalarPaths.contains(pathID) ? .scalar(0) : .binary(false)
    }
}

// MARK: - Gestures

/// Port of ALVR v20.14.1's `server_core/src/hand_gestures.rs` with its
/// default `HandTrackingInteractionConfig` (`session/src/settings.rs`): a
/// pinch of the thumb with index/middle/ring/little and finger curls become
/// Touch-controller buttons, so games that need buttons work with hands.
///
/// | gesture             | left                 | right                |
/// |---------------------|----------------------|----------------------|
/// | thumb-index pinch   | trigger value, touch | trigger value, touch |
/// | thumb-middle pinch  | Y click, touch       | B click, touch       |
/// | thumb-ring pinch    | X click, touch       | A click, touch       |
/// | thumb-little pinch  | menu click           | -                    |
/// | middle+ring+little curl | squeeze value    | squeeze value        |
/// | thumb tucked to palm | thumbstick click    | thumbstick click     |
/// | thumb on index side, fist | thumbstick x/y, touch | same         |
public struct AlvrHandGestureRecognizer: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var pinchTouchDistance: Float = 0.0      // meters
        public var pinchTriggerDistance: Float = 0.0025
        public var curlTouchDistance: Float = 0.02
        public var curlTriggerDistance: Float = 0.025
        public var joystickDeadzone: Float = 0.40
        public var joystickOffsetHorizontal: Float = 0
        public var joystickOffsetVertical: Float = 0
        public var joystickRange: Float = 0.01
        public var repeatDelayMilliseconds: Double = 100
        public var activationDelayMilliseconds: Double = 50
        public var deactivationDelayMilliseconds: Double = 100
        public init() {}
    }

    enum Pinch: Int, CaseIterable { case index, middle, ring, little }

    private struct Debounce: Sendable {
        var active = false
        var entering = false
        var enteringSince = 0.0
        var exiting = false
        var exitingSince = 0.0
        var lastDeactivated = -Double.infinity

        /// ALVR's `is_gesture_active`: in range for activation_delay to turn
        /// on (and not within repeat_delay of the last release), out of
        /// range for deactivation_delay to turn off.
        mutating func update(inRange: Bool, now: Double,
                             configuration: Configuration) -> Bool {
            if inRange { exiting = false } else { entering = false }
            if inRange, !active,
               lastDeactivated < now - configuration.repeatDelayMilliseconds {
                if entering {
                    if enteringSince < now - configuration.activationDelayMilliseconds {
                        entering = false
                        active = true
                    }
                } else {
                    entering = true
                    enteringSince = now
                }
            }
            if !inRange, active {
                if exiting {
                    if exitingSince < now - configuration.deactivationDelayMilliseconds {
                        lastDeactivated = now
                        exiting = false
                        active = false
                    }
                } else {
                    exiting = true
                    exitingSince = now
                }
            }
            return active
        }
    }

    // Finger-tip radii and palm depth from ALVR (surface, not center, distance).
    static let thumbRadius: Float = 0.0075
    static let fingerRadii: [Float] = [0.0065, 0.0065, 0.006, 0.005]
    static let palmDepth: Float = 0.005

    public let hand: AlvrHand
    public var configuration: Configuration
    private var pinches = [Debounce](repeating: Debounce(), count: 4)

    public init(hand: AlvrHand, configuration: Configuration = Configuration()) {
        self.hand = hand
        self.configuration = configuration
    }

    public mutating func reset() {
        pinches = [Debounce](repeating: Debounce(), count: 4)
    }

    /// Button values for one skeleton sample at `nowMilliseconds` (any
    /// monotonic clock). Every gesture-driven path of the hand is present.
    public mutating func buttons(for skeleton: AlvrHandSkeleton,
                                 nowMilliseconds now: Double) -> [UInt64: AlvrButtonValue] {
        let c = configuration
        let thumbTip = skeleton[.thumbTip].position
        let tips: [AlvrHandSkeleton.Joint] = [.indexTip, .middleTip, .ringTip, .littleTip]

        func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_distance(a, b) }
        func within(_ a: SIMD3<Float>, _ ra: Float, _ b: SIMD3<Float>, _ rb: Float,
                    _ threshold: Float) -> Bool {
            distance(a, b) < threshold + ra + rb
        }
        func hover(_ a: SIMD3<Float>, _ ra: Float, _ b: SIMD3<Float>, _ rb: Float,
                   _ minimum: Float, _ maximum: Float) -> Float {
            min(max(1 - (distance(a, b) - minimum - ra - rb) / (maximum + ra + rb), 0), 1)
        }

        // Pinches: active (debounced), clicked, touching, value.
        var pinchActive = [Bool](), pinchClicked = [Bool](), pinchTouching = [Bool]()
        var pinchValue = [Float]()
        for (index, tip) in tips.enumerated() {
            let tipPosition = skeleton[tip].position
            let radius = Self.fingerRadii[index]
            pinchActive.append(pinches[index].update(
                inRange: within(thumbTip, Self.thumbRadius, tipPosition, radius,
                                c.pinchTriggerDistance),
                now: now, configuration: c))
            pinchClicked.append(within(thumbTip, Self.thumbRadius, tipPosition, radius,
                                       c.pinchTouchDistance))
            pinchTouching.append(within(thumbTip, Self.thumbRadius, tipPosition, radius,
                                        c.pinchTriggerDistance))
            pinchValue.append(hover(thumbTip, Self.thumbRadius, tipPosition, radius,
                                    c.pinchTouchDistance, c.pinchTriggerDistance))
        }

        // Curls: the tip against the middle of its metacarpal and proximal.
        func anchor(_ a: AlvrHandSkeleton.Joint, _ b: AlvrHandSkeleton.Joint) -> SIMD3<Float> {
            simd_mix(skeleton[a].position, skeleton[b].position, SIMD3(repeating: 0.5))
        }
        let thumbCurl = hover(skeleton[.palm].position, Self.palmDepth, thumbTip,
                              Self.thumbRadius, c.curlTouchDistance, c.curlTriggerDistance)
        let indexCurl = hover(anchor(.indexMetacarpal, .indexProximal), Self.palmDepth,
                              skeleton[.indexTip].position, Self.fingerRadii[0],
                              c.curlTouchDistance, c.curlTriggerDistance)
        let middleCurl = hover(anchor(.middleMetacarpal, .middleProximal), Self.palmDepth,
                               skeleton[.middleTip].position, Self.fingerRadii[1],
                               c.curlTouchDistance, c.curlTriggerDistance)
        let ringCurl = hover(anchor(.ringMetacarpal, .ringProximal), Self.palmDepth,
                             skeleton[.ringTip].position, Self.fingerRadii[2],
                             c.curlTouchDistance, c.curlTriggerDistance)
        let littleCurl = hover(anchor(.littleMetacarpal, .littleProximal), Self.palmDepth,
                               skeleton[.littleTip].position, Self.fingerRadii[3],
                               c.curlTouchDistance, c.curlTriggerDistance)
        let grip = (middleCurl + ringCurl + littleCurl) / 3

        // Joystick: the thumb tip against the side of the index finger.
        let side: Float = hand == .left ? 1 : -1
        let intermediate = skeleton[.indexIntermediate]
        let centerRotation = simd_slerp(intermediate.rotation, skeleton[.indexDistal].rotation, 0.5)
        let center = simd_mix(intermediate.position, skeleton[.indexDistal].position,
                              SIMD3(repeating: 0.5))
        let up = centerRotation.act(SIMD3(side, 0, 0))
        let horizontal = intermediate.rotation.act(SIMD3(0, side, 0))
        let vertical = intermediate.rotation.act(SIMD3(0, 0, 1))
        let fromCenter = thumbTip - center
        let rawX = simd_dot(fromCenter, horizontal) / simd_length(horizontal)
            + c.joystickOffsetHorizontal * side
        let rawY = simd_dot(fromCenter, vertical) / simd_length(vertical)
            + c.joystickOffsetVertical
        let stickX = min(max(rawX / c.joystickRange, -1), 1)
        let stickY = min(max(rawY / c.joystickRange, -1), 1)
        let contact = indexCurl >= 0.75 && grip > 0.5
            && simd_distance(center, thumbTip) <= c.joystickRange * 3
            && simd_dot(fromCenter, up) / simd_length(up) <= c.joystickRange * 2

        typealias P = AlvrTouchPath
        let left = hand == .left
        var values: [UInt64: AlvrButtonValue] = [:]
        values[left ? P.leftTriggerValue : P.rightTriggerValue] =
            .scalar(pinchActive[0] ? pinchValue[0] : 0)
        values[left ? P.leftTriggerTouch : P.rightTriggerTouch] =
            .binary(pinchActive[0] && pinchTouching[0])
        values[left ? P.leftYClick : P.rightBClick] = .binary(pinchActive[1] && pinchClicked[1])
        values[left ? P.leftYTouch : P.rightBTouch] = .binary(pinchActive[1] && pinchTouching[1])
        values[left ? P.leftXClick : P.rightAClick] = .binary(pinchActive[2] && pinchClicked[2])
        values[left ? P.leftXTouch : P.rightATouch] = .binary(pinchActive[2] && pinchTouching[2])
        if left {
            values[P.leftMenuClick] = .binary(pinchActive[3] && pinchClicked[3])
        }
        values[left ? P.leftSqueezeValue : P.rightSqueezeValue] = .scalar(grip > 0 ? grip : 0)
        values[left ? P.leftThumbstickClick : P.rightThumbstickClick] = .binary(thumbCurl >= 0.5)
        values[left ? P.leftThumbstickTouch : P.rightThumbstickTouch] = .binary(contact)
        values[left ? P.leftThumbstickX : P.rightThumbstickX] =
            .scalar(contact && abs(stickX) >= c.joystickDeadzone ? stickX : 0)
        values[left ? P.leftThumbstickY : P.rightThumbstickY] =
            .scalar(contact && abs(stickY) >= c.joystickDeadzone ? stickY : 0)
        return values
    }
}

// MARK: - Router

/// Turns ALVR tracking, buttons, and interaction profiles into what the
/// runtime should see, per hand:
/// - Controller in hand: the client's pose (with `.meta`, Meta's grip pose:
///   ALVR's client offset removed), the client's buttons and profile.
/// - Hand tracked (no controller): an emulated Touch controller — grip from
///   the palm, gesture buttons, the Touch profile — plus the hand skeleton
///   for XR_EXT_hand_tracking. The client's buttons for that hand are held
///   back and restored when the controller returns.
/// Switching happens per tracking packet, so putting a controller down or
/// picking it up mid-session changes the source without a profile change.
/// Thread-safe; outputs are called with the internal lock released.
public final class HandTrackingInputRouter: @unchecked Sendable {
    public struct Outputs {
        public var controllerMotion: (_ timestamp: UInt64, _ hand: AlvrHand,
                                      _ motion: AlvrControllerMotion) -> Void = { _, _, _ in }
        public var controllerMask: (_ timestamp: UInt64, _ mask: UInt32) -> Void = { _, _ in }
        public var handSkeleton: (_ timestamp: UInt64, _ hand: AlvrHand,
                                  _ skeleton: AlvrHandSkeleton?) -> Void = { _, _, _ in }
        public var buttons: (_ entries: [AlvrButtonEntry]) -> Void = { _ in }
        public var interactionProfile: (_ deviceID: UInt64, _ profileID: UInt64) -> Void = { _, _ in }
        public var modeChanged: (_ hand: AlvrHand, _ handTracked: Bool) -> Void = { _, _ in }
        public init() {}
    }

    private let lock = NSLock()
    private let handTrackingEnabled: Bool
    private let gripPose: ControllerGripPose
    private let clock: () -> Double
    private let outputs: Outputs
    private var handTracked: [AlvrHand: Bool] = [.left: false, .right: false]
    private var recognizers: [AlvrHand: AlvrHandGestureRecognizer] = [
        .left: AlvrHandGestureRecognizer(hand: .left),
        .right: AlvrHandGestureRecognizer(hand: .right),
    ]
    /// Latest value per path from the client; replayed when a hand returns
    /// to its controller.
    private var clientButtons: [UInt64: AlvrButtonValue] = [:]
    /// Latest value per path as published to the runtime.
    private var publishedButtons: [UInt64: AlvrButtonValue] = [:]
    private var clientProfiles: [AlvrHand: UInt64] = [:]
    private var publishedProfiles: [AlvrHand: UInt64] = [:]

    /// `handTrackingEnabled` false ignores hand skeletons: a hand-tracked
    /// hand is then reported as untracked (no palm pose posing as a grip).
    /// `gripPose` applies to controllers only; a tracked hand's grip always
    /// comes from the palm.
    public init(handTrackingEnabled: Bool, gripPose: ControllerGripPose = .alvr,
                outputs: Outputs,
                clock: @escaping () -> Double = {
                    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
                }) {
        self.handTrackingEnabled = handTrackingEnabled
        self.gripPose = gripPose
        self.outputs = outputs
        self.clock = clock
    }

    public func handleTracking(_ sample: AlvrTrackingSample) {
        var actions: [() -> Void] = []
        let timestamp = sample.timestampNanoseconds
        lock.lock()
        let now = clock()
        var mask: UInt32 = 0
        for hand in [AlvrHand.left, .right] {
            let skeleton = sample.skeleton(hand)
            if let skeleton, handTrackingEnabled {
                if handTracked[hand] != true {
                    handTracked[hand] = true
                    actions.append { [outputs] in outputs.modeChanged(hand, true) }
                    if publishedProfiles[hand] != AlvrTouchPath.questTouchProfileID {
                        publishedProfiles[hand] = AlvrTouchPath.questTouchProfileID
                        actions.append { [outputs] in
                            outputs.interactionProfile(hand.alvrDeviceID,
                                                       AlvrTouchPath.questTouchProfileID)
                        }
                    }
                    // Release inputs the gestures never drive (thumb rest,
                    // system) so a held controller value cannot stick.
                    var released: [UInt64: AlvrButtonValue] = [:]
                    for path in AlvrTouchPath.paths(hand) {
                        released[path] = AlvrTouchPath.released(path)
                    }
                    actions += publishChangesLocked(released)
                }
                let grip = AlvrGripPose.handGrip(from: skeleton, hand: hand)
                mask |= 1 << hand.rawValue
                let gestures = recognizers[hand]!.buttons(for: skeleton, nowMilliseconds: now)
                actions.append { [outputs] in
                    outputs.controllerMotion(timestamp, hand, grip)
                    outputs.handSkeleton(timestamp, hand, skeleton)
                }
                actions += publishChangesLocked(gestures)
            } else {
                if handTracked[hand] == true {
                    handTracked[hand] = false
                    recognizers[hand]!.reset()
                    actions.append { [outputs] in
                        outputs.handSkeleton(timestamp, hand, nil)
                        outputs.modeChanged(hand, false)
                    }
                    var restored: [UInt64: AlvrButtonValue] = [:]
                    for path in AlvrTouchPath.paths(hand) {
                        restored[path] = clientButtons[path] ?? AlvrTouchPath.released(path)
                    }
                    actions += publishChangesLocked(restored)
                    if let profile = clientProfiles[hand], publishedProfiles[hand] != profile {
                        publishedProfiles[hand] = profile
                        actions.append { [outputs] in
                            outputs.interactionProfile(hand.alvrDeviceID, profile)
                        }
                    }
                }
                // A skeleton with hand tracking off means this motion is a
                // palm pose, not a controller: report the hand untracked.
                if skeleton == nil, let motion = sample.motion(hand) {
                    let grip = gripPose == .meta
                        ? AlvrGripPose.controllerGrip(fromALVR: motion, hand: hand)
                        : motion
                    mask |= 1 << hand.rawValue
                    actions.append { [outputs] in outputs.controllerMotion(timestamp, hand, grip) }
                }
            }
        }
        lock.unlock()
        for action in actions { action() }
        outputs.controllerMask(timestamp, mask)
    }

    public func handleClientButtons(_ entries: [AlvrButtonEntry]) {
        lock.lock()
        var forwarded: [UInt64: AlvrButtonValue] = [:]
        var order: [UInt64] = []
        for entry in entries {
            clientButtons[entry.pathID] = entry.value
            if let hand = AlvrTouchPath.hand(of: entry.pathID), handTracked[hand] == true {
                continue
            }
            if forwarded[entry.pathID] == nil { order.append(entry.pathID) }
            forwarded[entry.pathID] = entry.value
        }
        for (path, value) in forwarded { publishedButtons[path] = value }
        lock.unlock()
        let out = order.map { AlvrButtonEntry(pathID: $0, value: forwarded[$0]!) }
        if !out.isEmpty { outputs.buttons(out) }
    }

    public func handleClientInteractionProfile(deviceID: UInt64, profileID: UInt64) {
        guard let hand = AlvrHand(alvrDeviceID: deviceID) else {
            outputs.interactionProfile(deviceID, profileID)
            return
        }
        lock.lock()
        clientProfiles[hand] = profileID
        let forward = handTracked[hand] != true && publishedProfiles[hand] != profileID
        if forward { publishedProfiles[hand] = profileID }
        lock.unlock()
        if forward { outputs.interactionProfile(deviceID, profileID) }
    }

    /// The ALVR session ended (the runtime gets INPUT_RESET separately).
    public func reset() {
        lock.lock()
        handTracked = [.left: false, .right: false]
        recognizers[.left]!.reset()
        recognizers[.right]!.reset()
        clientButtons.removeAll()
        publishedButtons.removeAll()
        clientProfiles.removeAll()
        publishedProfiles.removeAll()
        lock.unlock()
    }

    /// Publishes only values that differ from what the runtime has.
    private func publishChangesLocked(_ values: [UInt64: AlvrButtonValue]) -> [() -> Void] {
        var entries: [AlvrButtonEntry] = []
        for (path, value) in values.sorted(by: { $0.key < $1.key })
        where publishedButtons[path] != value {
            publishedButtons[path] = value
            entries.append(AlvrButtonEntry(pathID: path, value: value))
        }
        guard !entries.isEmpty else { return [] }
        return [{ [outputs] in outputs.buttons(entries) }]
    }
}
