import Foundation

/// ALVR v20 stream-socket sharding for video stream ID 3.
public enum AlvrVideoPacketizer {
    public static let videoStreamId: UInt16 = 3
    public static let defaultPacketSize = 1_400
    private static let shardPrefixSize = 18

    /// Packetizes one encoded access unit. ALVR adds four bytes to the
    /// configured packet size for legacy compatibility, hence 1404 bytes on
    /// the wire with the default setting.
    public static func shards(
        annexB: Data,
        timestampNanoseconds: UInt64,
        isIDR: Bool,
        packetIndex: UInt32,
        configuredPacketSize: Int = defaultPacketSize
    ) throws -> [Data] {
        let wirePacketSize = configuredPacketSize + 4
        guard wirePacketSize > shardPrefixSize else {
            throw BasaltError("ALVR packet size is too small")
        }

        var logicalPacket = Data(repeating: 0, count: shardPrefixSize)
        appendLittleEndian(timestampNanoseconds / 1_000_000_000, to: &logicalPacket)
        appendLittleEndian(UInt32(timestampNanoseconds % 1_000_000_000), to: &logicalPacket)
        logicalPacket.append(isIDR ? 1 : 0)
        logicalPacket.append(annexB)

        let maximumShardData = wirePacketSize - shardPrefixSize
        let dataSize = logicalPacket.count - shardPrefixSize
        let shardCount = max(1, (dataSize + maximumShardData - 1) / maximumShardData)
        var result = [Data]()
        result.reserveCapacity(shardCount)

        for shardIndex in 0..<shardCount {
            let start = shardIndex * maximumShardData
            let packetLength = min(wirePacketSize, logicalPacket.count - start)
            var shard = Data(logicalPacket[start..<start + packetLength])
            writeBigEndian(UInt32(packetLength - 4), at: 0, in: &shard)
            writeBigEndian(videoStreamId, at: 4, in: &shard)
            writeBigEndian(packetIndex, at: 6, in: &shard)
            writeBigEndian(UInt32(shardCount), at: 10, in: &shard)
            writeBigEndian(UInt32(shardIndex), at: 14, in: &shard)
            result.append(shard)
        }
        return result
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T,
                                                                  to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func writeBigEndian<T: FixedWidthInteger>(_ value: T, at offset: Int,
                                                              in data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<offset + $0.count, with: $0) }
    }
}

/// ALVR v20 game-audio stream ID 2. The payload is headerless raw stereo
/// signed 16-bit PCM in native/little-endian order, matching upstream's
/// `StreamSender<()>` and Android Float32 playback conversion.
public enum AlvrAudioPacketizer {
    public static let streamID: UInt16 = 2

    public static func shards(
        pcm16Stereo: Data,
        packetIndex: UInt32,
        configuredPacketSize: Int = AlvrVideoPacketizer.defaultPacketSize
    ) throws -> [Data] {
        guard !pcm16Stereo.isEmpty, pcm16Stereo.count.isMultiple(of: 4) else {
            throw BasaltError("ALVR audio must contain complete stereo PCM16 frames")
        }
        let prefixSize = 18
        let wirePacketSize = configuredPacketSize + 4
        guard wirePacketSize > prefixSize else {
            throw BasaltError("ALVR packet size is too small")
        }

        var logicalPacket = Data(repeating: 0, count: prefixSize)
        logicalPacket.append(pcm16Stereo)
        let maximumShardData = wirePacketSize - prefixSize
        let shardCount = max(
            1, (pcm16Stereo.count + maximumShardData - 1) / maximumShardData)
        var result = [Data]()
        result.reserveCapacity(shardCount)
        for shardIndex in 0..<shardCount {
            let start = shardIndex * maximumShardData
            let packetLength = min(wirePacketSize, logicalPacket.count - start)
            var shard = Data(logicalPacket[start..<start + packetLength])
            writeBigEndian(UInt32(packetLength - 4), at: 0, in: &shard)
            writeBigEndian(streamID, at: 4, in: &shard)
            writeBigEndian(packetIndex, at: 6, in: &shard)
            writeBigEndian(UInt32(shardCount), at: 10, in: &shard)
            writeBigEndian(UInt32(shardIndex), at: 14, in: &shard)
            result.append(shard)
        }
        return result
    }

    private static func writeBigEndian<T: FixedWidthInteger>(
        _ value: T, at offset: Int, in data: inout Data
    ) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) {
            data.replaceSubrange(offset..<offset + $0.count, with: $0)
        }
    }
}

/// Diagnostic trace of every runtime haptic forwarded to ALVR, enabled by
/// `BASALT_HAPTIC_LOG` (any value but empty or `0`). The OpenXR runtime logs
/// the game's raw values under the same variable.
public enum AlvrHapticsLog {
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let value = environment["BASALT_HAPTIC_LOG"] else { return false }
        return !value.isEmpty && value != "0"
    }

    public static func line(hand: AlvrHand, durationNanoseconds: UInt64,
                            frequency: Float, amplitude: Float,
                            uptimeNanoseconds: UInt64) -> String {
        let kind = durationNanoseconds == 0 && amplitude == 0 ? "stop" : "pulse"
        let handName = hand == .left ? "left" : "right"
        return "haptic t=\(uptimeNanoseconds / 1_000_000)ms \(handName) \(kind) "
            + "duration=\(durationNanoseconds)ns frequency=\(frequency) amplitude=\(amplitude)"
    }
}

/// Fixed-size ALVR v20 haptics stream header (stream ID 1). Haptics shares
/// the video socket but keeps its own packet-index sequence. The payload is
/// bincode of `alvr_packets::Haptics { device_id: u64, duration: Duration,
/// frequency: f32, amplitude: f32 }`, Duration as `secs: u64, nanos: u32`.
/// The ALVR v20.14.1 client passes these to xrApplyHapticFeedback as-is:
/// duration in nanoseconds, frequency in Hz (0 is unspecified), amplitude
/// clamped to 0...1. Zero duration and amplitude is the stop the runtime sends.
public enum AlvrHapticsPacketizer {
    public static let streamID: UInt16 = 1

    public static func packet(hand: AlvrHand, durationNanoseconds: UInt64,
                              frequency: Float, amplitude: Float,
                              packetIndex: UInt32) throws -> Data {
        guard frequency.isFinite, frequency >= 0,
              amplitude.isFinite, amplitude >= 0, amplitude <= 1 else {
            throw BasaltError("Invalid ALVR haptic parameters")
        }
        var packet = Data(repeating: 0, count: 18)
        appendLittleEndian(hand.alvrDeviceID, to: &packet)
        appendLittleEndian(durationNanoseconds / 1_000_000_000, to: &packet)
        appendLittleEndian(UInt32(durationNanoseconds % 1_000_000_000), to: &packet)
        appendLittleEndian(frequency.bitPattern, to: &packet)
        appendLittleEndian(amplitude.bitPattern, to: &packet)
        writeBigEndian(UInt32(packet.count - 4), at: 0, in: &packet)
        writeBigEndian(streamID, at: 4, in: &packet)
        writeBigEndian(packetIndex, at: 6, in: &packet)
        writeBigEndian(UInt32(1), at: 10, in: &packet)
        writeBigEndian(UInt32(0), at: 14, in: &packet)
        return packet
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T,
                                                                  to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func writeBigEndian<T: FixedWidthInteger>(_ value: T, at offset: Int,
                                                              in data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) {
            data.replaceSubrange(offset..<offset + $0.count, with: $0)
        }
    }
}
