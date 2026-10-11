import Foundation
import BasaltCore

/// A problem the live dashboard can explain, with a suggestion the user can
/// act on for the next session.
public struct StreamHealthIssue: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case headsetSilent
        case lowFrameRate
        case highLatency
        case thermalPressure
        case lowPowerMode
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let title: String
    public let detail: String
}

/// Turns the recent dashboard samples and Mac power state into issues,
/// most severe first. Rules look at medians of the latest reports so one
/// slow frame or a reconnect blip does not raise a warning.
public enum StreamHealthAdvisor {
    /// Latest reports per series that each rule considers.
    public static let window = 8
    /// Reports required before a rate or latency rule can fire.
    public static let minimumReports = 5
    /// Silence after which a previously reporting headset is flagged.
    public static let silenceThreshold: TimeInterval = 6

    public static func evaluate(
        samples: [StreamMetricSample],
        settings: StreamLaunchSettings,
        thermalState: ProcessInfo.ThermalState = .nominal,
        lowPowerMode: Bool = false,
        now: Date = Date()
    ) -> [StreamHealthIssue] {
        var issues = [StreamHealthIssue]()
        let fpsReports = samples.filter { $0.fps != nil }

        if let last = fpsReports.last,
           now.timeIntervalSince(last.date) > silenceThreshold {
            issues.append(StreamHealthIssue(
                kind: .headsetSilent,
                title: "The headset stopped reporting frames",
                detail: "No Quest frame report for \(Int(now.timeIntervalSince(last.date))) s. "
                    + "Check that the Quest is awake and ALVR is in the foreground"
                    + (settings.connection == .wired
                        ? ", and that the USB cable is still connected."
                        : ", and that it is still on the same Wi-Fi network.")))
        } else if let observed = median(of: fpsReports.suffix(window).compactMap(\.fps)),
                  settings.fps > 0,
                  observed < Double(settings.fps) * StreamMetricSummary.lowFrameRateFraction {
            issues.append(StreamHealthIssue(
                kind: .lowFrameRate,
                title: "Below the target frame rate",
                detail: String(format: "The Quest reports %.0f fps against a %d fps target. ",
                               observed, settings.fps)
                    + frameRateSuggestion(for: settings)))
        }

        let latencies = samples.compactMap(\.latencyMilliseconds).suffix(window)
        if let observed = median(of: Array(latencies)),
           observed > latencyBudget(for: settings.latency) {
            issues.append(StreamHealthIssue(
                kind: .highLatency,
                title: "High input-to-display latency",
                detail: String(format: "Latency is about %.0f ms. ", observed)
                    + latencySuggestion(for: settings)))
        }

        if thermalState == .serious || thermalState == .critical {
            issues.append(StreamHealthIssue(
                kind: .thermalPressure,
                title: "Your Mac is running hot",
                detail: "macOS may be throttling the GPU and encoder. Improve airflow, "
                    + "close other demanding apps, or use a lower resolution."))
        }

        if lowPowerMode {
            issues.append(StreamHealthIssue(
                kind: .lowPowerMode,
                title: "Low Power Mode is on",
                detail: "It limits GPU and encoder performance. Turn it off in "
                    + "System Settings › Battery while playing."))
        }
        return issues
    }

    /// Median latency above which a preset is flagged. Measured Quest 3
    /// pipelines run about 47–58 ms (docs/STREAMER.md), so these leave room
    /// for normal variance and only catch clearly degraded sessions.
    public static func latencyBudget(for preset: StreamLatencyPreset) -> Double {
        switch preset {
        case .balanced: return 90
        case .low: return 80
        case .ultra: return 75
        }
    }

    private static func frameRateSuggestion(for settings: StreamLaunchSettings) -> String {
        if settings.resolution == .quality {
            return "Try the Balanced resolution for this game next session."
        }
        if settings.fps > 72 {
            return "Try 72 fps for this game next session."
        }
        if settings.connection == .wifi, settings.megabits > 60 {
            return "Try a lower bitrate or a USB cable."
        }
        if settings.resolution == .balanced {
            return "Try the Performance resolution for this game next session."
        }
        return "Close other demanding apps and keep the Mac on power."
    }

    private static func latencySuggestion(for settings: StreamLaunchSettings) -> String {
        if settings.connection == .wifi {
            return "Wi-Fi adds latency; a USB cable or an uncongested 5 or 6 GHz network helps."
        }
        switch settings.latency {
        case .balanced: return "Try the Low latency preset."
        case .low: return "Try the Ultra Low latency preset."
        case .ultra: return "Try a lower bitrate or resolution."
        }
    }

    static func median(of values: [Double]) -> Double? {
        guard values.count >= minimumReports else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
