import Foundation

/// Running count, mean, and range of one metric series. It keeps no samples,
/// so a session of any length summarizes in constant space.
public struct MetricStatistics: Codable, Equatable, Sendable {
    public private(set) var count = 0
    public private(set) var sum = 0.0
    public private(set) var minimum: Double?
    public private(set) var maximum: Double?

    public init() {}

    public init<Values: Sequence>(_ values: Values) where Values.Element == Double {
        values.forEach { add($0) }
    }

    public var average: Double? { count > 0 ? sum / Double(count) : nil }

    public mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        count += 1
        sum += value
        minimum = Swift.min(minimum ?? value, value)
        maximum = Swift.max(maximum ?? value, value)
    }
}

/// Whole-session aggregates of the dashboard series. The dashboard itself
/// keeps only a recent window, so history and diagnostics use this instead.
public struct StreamMetricSummary: Codable, Equatable, Sendable {
    /// A Quest FPS report below this fraction of the target counts as low.
    public static let lowFrameRateFraction = 0.9

    public var fps = MetricStatistics()
    public var megabits = MetricStatistics()
    public var latencyMilliseconds = MetricStatistics()
    /// Quest FPS reports below `lowFrameRateFraction` of the target rate.
    public var lowFrameRateSamples = 0

    public init() {}

    public init(samples: [StreamMetricSample], targetFPS: Int) {
        for sample in samples { add(sample, targetFPS: targetFPS) }
    }

    public var isEmpty: Bool {
        fps.count == 0 && megabits.count == 0 && latencyMilliseconds.count == 0
    }

    /// Share of Quest FPS reports that fell below the target, if any arrived.
    public var lowFrameRateShare: Double? {
        fps.count > 0 ? Double(lowFrameRateSamples) / Double(fps.count) : nil
    }

    public mutating func add(_ sample: StreamMetricSample, targetFPS: Int) {
        if let value = sample.fps, value.isFinite {
            fps.add(value)
            if targetFPS > 0, value < Double(targetFPS) * Self.lowFrameRateFraction {
                lowFrameRateSamples += 1
            }
        }
        if let value = sample.megabits { megabits.add(value) }
        if let value = sample.latencyMilliseconds { latencyMilliseconds.add(value) }
    }
}

/// One VR session the manager launched, kept for the Stream page's history
/// and for diagnostic reports.
public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The game exited on its own.
        case ended
        /// The user stopped the session.
        case stopped
        /// Startup or the streamer failed; `failureReason` says why.
        case failed
    }

    public let id: UUID
    public var profileName: String
    public var settings: StreamLaunchSettings
    public var startedAt: Date
    /// When the game was launched against a ready streamer; nil if startup
    /// never got that far.
    public var streamingStartedAt: Date?
    public var endedAt: Date?
    public var outcome: Outcome?
    public var failureReason: String?
    public var metrics: StreamMetricSummary

    public init(id: UUID = UUID(), profileName: String,
                settings: StreamLaunchSettings, startedAt: Date = Date()) {
        self.id = id
        self.profileName = profileName
        self.settings = settings
        self.startedAt = startedAt
        metrics = StreamMetricSummary()
    }

    /// Time spent streaming, excluding Steam and streamer startup.
    public var streamingDuration: TimeInterval? {
        guard let streamingStartedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(streamingStartedAt))
    }
}

/// Persists recent `SessionRecord`s as JSON in the Basalt data root, newest
/// first. History is advisory: an unreadable file loads as empty and is
/// replaced by the next save, and records from an incompatible future format
/// are skipped individually rather than discarding the rest.
public struct SessionHistoryStore: Sendable {
    public static let defaultLimit = 50
    public static let fileName = "SessionHistory.json"

    public let file: URL
    public let limit: Int

    public init(file: URL, limit: Int = defaultLimit) {
        self.file = file
        self.limit = max(1, limit)
    }

    public init(dataRoot: URL, limit: Int = defaultLimit) {
        self.init(file: dataRoot.appendingPathComponent(Self.fileName), limit: limit)
    }

    public func load() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: file),
              let document = try? Self.decoder.decode(Document.self, from: data)
        else { return [] }
        return Array(document.sessions.compactMap(\.value).prefix(limit))
    }

    /// Prepends `record` (replacing an older copy with the same ID) and
    /// returns the saved history.
    @discardableResult
    public func append(_ record: SessionRecord) throws -> [SessionRecord] {
        let records = [record] + load().filter { $0.id != record.id }
        return try save(records)
    }

    @discardableResult
    public func save(_ records: [SessionRecord]) throws -> [SessionRecord] {
        let kept = Array(records.prefix(limit))
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = Document(
            formatVersion: Document.currentFormatVersion,
            sessions: kept.map { Lossy(value: $0) })
        try Self.encoder.encode(document).write(to: file, options: .atomic)
        return kept
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    private struct Document: Codable {
        static let currentFormatVersion = 1
        var formatVersion: Int
        var sessions: [Lossy<SessionRecord>]
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Decodes to nil instead of failing the enclosing array.
private struct Lossy<Value: Codable>: Codable {
    let value: Value?

    init(value: Value) { self.value = value }

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

/// The dashboard series as CSV, for comparing runs in a spreadsheet.
public enum StreamMetricCSV {
    public static let header = "timestamp,quest_fps,wire_mbps,input_to_display_ms"

    public static func render(_ samples: [StreamMetricSample]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [header]
        lines.reserveCapacity(samples.count + 1)
        for sample in samples {
            lines.append([
                formatter.string(from: sample.date),
                cell(sample.fps),
                cell(sample.megabits),
                cell(sample.latencyMilliseconds),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func cell(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(value)
    }
}
