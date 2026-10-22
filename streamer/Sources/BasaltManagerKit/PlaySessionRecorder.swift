import Foundation

/// Builds the history record of one Play page session (scripts/play.zsh) from
/// its events and streamer lines, with the same rules as a Stream page
/// session: a launch stopped before the game started is not recorded, and
/// a failure is recorded even if the game never started.
public struct PlaySessionRecorder: Sendable {
    public private(set) var record: SessionRecord
    private let quality: PlayQuality
    private var stopRequested = false
    private var gameEnded = false
    private var failure: PlayFailure?

    public init(profileName: String, options: PlayOptions, startedAt: Date = Date()) {
        quality = options.quality
        let link: PlayLink? = switch options.transport {
        case .usb: .usb
        case .wifi: .wifi
        case .auto: nil
        }
        record = SessionRecord(
            profileName: profileName,
            settings: Self.settings(link: link, quality: options.quality),
            startedAt: startedAt)
    }

    /// What play.zsh asks the streamer for on this link and quality
    /// (see the "Streamer" step in scripts/play.zsh).
    public static func settings(link: PlayLink?, quality: PlayQuality) -> StreamLaunchSettings {
        var settings = StreamLaunchSettings()
        settings.fps = 72
        settings.latency = .low
        switch (link ?? .usb, quality) {
        case (.usb, .high):
            settings.connection = .wired
            settings.resolution = .quality
            settings.megabits = 60
        case (.usb, .normal):
            settings.connection = .wired
            settings.resolution = .balanced
            settings.megabits = 30
        case (.wifi, .high):
            settings.connection = .wifi
            settings.resolution = .quality
            settings.megabits = PlayLaunchPlan.wifiHighMegabits
        case (.wifi, .normal):
            settings.connection = .wifi
            settings.resolution = .quality
            settings.megabits = 20
        }
        return settings
    }

    public mutating func apply(_ event: PlayEvent, at date: Date = Date()) {
        switch event {
        case .connection(let link):
            var settings = Self.settings(link: link, quality: quality)
            settings.audioDeviceName = record.settings.audioDeviceName
            record.settings = settings
        case .gameStart:
            if record.streamingStartedAt == nil { record.streamingStartedAt = date }
        case .gameEnded:
            gameEnded = true
        case .fail(let reason):
            if failure == nil { failure = reason }
        default:
            break
        }
    }

    public mutating func apply(streamerLine line: String, at date: Date = Date()) {
        guard let sample = StreamLogMetricsParser.parse(line: line, date: date) else { return }
        record.metrics.add(sample, targetFPS: record.settings.fps)
    }

    /// The user pressed Stop.
    public mutating func requestStop() {
        stopRequested = true
    }

    /// play.zsh exited. Returns the record to save, or nil when there is no
    /// session to keep.
    public func finish(exitStatus: Int32, lastError: String?, at date: Date = Date()) -> SessionRecord? {
        var record = record
        if let failure, !stopRequested {
            record.outcome = .failed
            record.failureReason = failure.message
        } else if stopRequested {
            record.outcome = .stopped
        } else if gameEnded || exitStatus == 0 {
            record.outcome = .ended
        } else {
            record.outcome = .failed
            record.failureReason = lastError ?? "play.zsh exited with status \(exitStatus)"
        }
        guard record.streamingStartedAt != nil || record.outcome == .failed else { return nil }
        record.endedAt = date
        return record
    }
}

/// The app's own log of one session: `app-<profile>-<time>.log` in the
/// BasaltVR logs folder, next to play.zsh's streamer, game, and Quest logs.
public enum AppSessionLog {
    public static func fileName(profileName: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "app-\(ProfileNaming.slug(profileName))-\(formatter.string(from: date)).log"
    }

    /// Prunes old logs (the 7-day rule of scripts/log-retention.zsh), then
    /// creates a new log and opens it for writing.
    public static func open(
        profileName: String, in directory: URL = PlayTools.logsDirectory(), date: Date = Date()
    ) -> FileHandle? {
        LogRetention.pruneOldLogs(in: directory)
        let file = directory.appendingPathComponent(fileName(profileName: profileName, date: date))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { return nil }
        return try? FileHandle(forWritingTo: file)
    }
}
