import Foundation

/// Keeps a wireless stream inside the capacity the current Wi-Fi path can
/// actually sustain. ALVR reports both displayed frame cadence and queueing
/// latency; persistent degradation backs VideoToolbox off, while a long
/// healthy interval cautiously restores quality.
public final class AdaptiveVideoBitrateController: @unchecked Sendable {
    private static let adjustmentCooldownNanoseconds: UInt64 = 2_000_000_000
    private static let unhealthyDurationNanoseconds: UInt64 = 1_000_000_000
    private static let healthyRecoveryNanoseconds: UInt64 = 12_000_000_000
    private static let congestionWindowNanoseconds: UInt64 = 2_000_000_000
    /// Statistics come from the headset. A pipeline latency this large is a
    /// corrupt or hostile sample, and would also overflow the latency math.
    static let maximumPlausibleLatencyNanoseconds: UInt64 = 10_000_000_000

    public let configuredBitrate: Int
    public let minimumBitrate: Int

    private let targetFrameIntervalNanoseconds: UInt64
    private let lock = NSLock()
    private var bitrate: Int
    private var baselineLatencyNanoseconds: UInt64?
    private var unhealthySince: UInt64?
    private var healthySince: UInt64?
    private var lastAdjustment: UInt64?
    private var lastCongestion: UInt64?
    private var congestionCount = 0

    public init(configuredBitrate: Int, targetFramesPerSecond: Int,
                minimumBitrate: Int? = nil) {
        precondition(configuredBitrate > 0)
        precondition(targetFramesPerSecond > 0)
        self.configuredBitrate = configuredBitrate
        self.minimumBitrate = min(
            configuredBitrate,
            minimumBitrate ?? max(8_000_000, configuredBitrate / 3))
        bitrate = configuredBitrate
        targetFrameIntervalNanoseconds =
            1_000_000_000 / UInt64(targetFramesPerSecond)
    }

    public var currentBitrate: Int {
        lock.lock()
        defer { lock.unlock() }
        return bitrate
    }

    /// Two nearby socket-pressure events indicate sustained congestion rather
    /// than one unusually large IDR. A single event still triggers decoder
    /// recovery, but does not sacrifice quality on its own.
    public func recordTransportCongestion(
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if let lastCongestion,
           nowNanoseconds >= lastCongestion,
           nowNanoseconds - lastCongestion <= Self.congestionWindowNanoseconds {
            congestionCount += 1
        } else {
            congestionCount = 1
        }
        lastCongestion = nowNanoseconds
        guard congestionCount >= 2,
              canAdjust(at: nowNanoseconds) else { return nil }
        congestionCount = 0
        return reduceBitrate(at: nowNanoseconds)
    }

    public func recordClientStatistics(
        _ statistics: AlvrClientStatistics,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Int? {
        guard statistics.frameIntervalNanoseconds > 0,
              statistics.totalPipelineLatencyNanoseconds > 0,
              statistics.totalPipelineLatencyNanoseconds
                <= Self.maximumPlausibleLatencyNanoseconds else { return nil }

        lock.lock()
        defer { lock.unlock() }
        let latency = statistics.totalPipelineLatencyNanoseconds
        baselineLatencyNanoseconds = min(
            baselineLatencyNanoseconds ?? latency, latency)
        let baseline = baselineLatencyNanoseconds ?? latency
        let slowFrame = statistics.frameIntervalNanoseconds
            > targetFrameIntervalNanoseconds * 10 / 9
        let latencyGrowth = latency > baseline + 25_000_000
        let decoderBacklog = statistics.videoDecoderQueueNanoseconds
            > targetFrameIntervalNanoseconds * 2
        let unhealthy = decoderBacklog || (slowFrame && latencyGrowth)

        if unhealthy {
            healthySince = nil
            if unhealthySince == nil { unhealthySince = nowNanoseconds }
            if let unhealthySince,
               nowNanoseconds >= unhealthySince,
               nowNanoseconds - unhealthySince >= Self.unhealthyDurationNanoseconds,
               canAdjust(at: nowNanoseconds) {
                self.unhealthySince = nil
                return reduceBitrate(at: nowNanoseconds)
            }
            return nil
        }

        unhealthySince = nil
        let nearTargetFrameRate = statistics.frameIntervalNanoseconds
            <= targetFrameIntervalNanoseconds * 20 / 19
        let lowLatency = latency <= baseline + 15_000_000
        let decoderClear = statistics.videoDecoderQueueNanoseconds
            <= targetFrameIntervalNanoseconds
        guard nearTargetFrameRate, lowLatency, decoderClear,
              bitrate < configuredBitrate else {
            healthySince = nil
            return nil
        }
        if healthySince == nil { healthySince = nowNanoseconds }
        guard let healthySince,
              nowNanoseconds >= healthySince,
              nowNanoseconds - healthySince >= Self.healthyRecoveryNanoseconds,
              canAdjust(at: nowNanoseconds) else { return nil }
        self.healthySince = nowNanoseconds
        let increased = min(
            configuredBitrate,
            max(bitrate + 1_000_000, Int(Double(bitrate) * 1.05)))
        guard increased > bitrate else { return nil }
        bitrate = increased
        lastAdjustment = nowNanoseconds
        return bitrate
    }

    private func canAdjust(at nowNanoseconds: UInt64) -> Bool {
        guard let lastAdjustment else { return true }
        return nowNanoseconds >= lastAdjustment
            && nowNanoseconds - lastAdjustment
                >= Self.adjustmentCooldownNanoseconds
    }

    private func reduceBitrate(at nowNanoseconds: UInt64) -> Int? {
        let reduced = max(minimumBitrate, Int(Double(bitrate) * 0.8))
        guard reduced < bitrate else { return nil }
        bitrate = reduced
        lastAdjustment = nowNanoseconds
        healthySince = nil
        return bitrate
    }
}
