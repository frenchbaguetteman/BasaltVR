import Combine
import Foundation

/// The live session log and its metric samples. Streamer, Steam, and Wine
/// output arrives in many small chunks, so this state lives apart from the
/// app model: each chunk re-renders only the views that show the log or the
/// charts, not the whole window.
@MainActor
public final class SessionConsole: ObservableObject {
    /// Past `maximumLogBytes` the log drops whole lines from the front,
    /// keeping about `retainedLogBytes`.
    public static let maximumLogBytes = 80_000
    public static let retainedLogBytes = 60_000
    /// Samples kept for CSV export; the charts show the last `chartWindow`.
    public static let maximumSamples = 50_000
    public static let chartWindow = 360
    /// A partial line longer than this is logged as it stands, so a process
    /// that never writes a newline cannot grow its buffer without bound.
    public static let maximumPartialLineBytes = 16_384

    @Published public private(set) var log = ""
    /// Every metric sample since the session started.
    @Published public private(set) var samples = [StreamMetricSample]()
    /// One pending partial line per output source (each process pipe, or
    /// nil for the app's own messages), so concurrent outputs never splice
    /// into each other mid-line.
    private var partialLines = [ObjectIdentifier?: String]()

    public init() {}

    /// The charts' and health checks' recent window of `samples`.
    public var recentSamples: [StreamMetricSample] {
        Array(samples.suffix(Self.chartWindow))
    }

    /// The newest non-empty log line, scanned back from the end so a render
    /// never copies the whole log.
    public var latestLine: String? {
        guard let end = log.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        let start = log[..<end].lastIndex(where: \.isNewline).map(log.index(after:))
            ?? log.startIndex
        return log[start...end].trimmingCharacters(in: .whitespaces)
    }

    /// Starts a new log. A stream session also clears the samples; a Windows
    /// utility keeps the last stream's charts.
    public func restart(with firstLine: String = "", clearingSamples: Bool = true) {
        log = firstLine
        partialLines.removeAll()
        if clearingSamples { samples.removeAll() }
    }

    /// Appends raw output from `source`, logs the lines it completed with
    /// `prefix`, and returns them. An unfinished line waits for its source's
    /// next chunk or `finish`.
    public func append(_ output: String, from source: ObjectIdentifier? = nil,
                       prefix: String = "") -> [String] {
        // Wine writes CRLF; split on LF and drop the CR so it adds no blank line.
        var lines = (partialLines[source, default: ""] + output)
            .components(separatedBy: "\n")
        var partial = lines.removeLast()
        lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if partial.utf8.count > Self.maximumPartialLineBytes {
            lines.append(partial)
            partial = ""
        }
        partialLines[source] = partial.isEmpty ? nil : partial
        return commit(lines, prefix: prefix)
    }

    /// Logs and returns the unfinished line `source` left when it closed.
    public func finish(_ source: ObjectIdentifier?, prefix: String = "") -> [String] {
        guard let partial = partialLines.removeValue(forKey: source) else { return [] }
        return commit([partial], prefix: prefix)
    }

    private func commit(_ lines: [String], prefix: String) -> [String] {
        guard !lines.isEmpty else { return [] }
        let prefixed = lines.map { prefix + $0 }
        log += prefixed.map { $0 + "\n" }.joined()
        if log.utf8.count > Self.maximumLogBytes { trimLog() }
        return prefixed
    }

    public func record(_ sample: StreamMetricSample) {
        samples.append(sample)
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples * 9 / 10)
        }
    }

    private func trimLog() {
        let bytes = log.utf8
        let cut = bytes.index(bytes.endIndex, offsetBy: -Self.retainedLogBytes)
        // Start on a line boundary rather than mid-line (or mid-character);
        // searching from the byte before `cut` keeps a line that starts there.
        let start = bytes[bytes.index(before: cut)...].firstIndex(of: UInt8(ascii: "\n"))
            .map(bytes.index(after:)) ?? cut
        log = String(log[start...])
    }
}
