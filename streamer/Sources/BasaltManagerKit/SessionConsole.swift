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

    @Published public private(set) var log = ""
    /// Every metric sample since the session started.
    @Published public private(set) var samples = [StreamMetricSample]()
    private var partialLine = ""

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
        partialLine = ""
        if clearingSamples { samples.removeAll() }
    }

    /// Appends raw output and returns the lines it completed.
    public func append(_ output: String) -> [String] {
        log += output
        if log.utf8.count > Self.maximumLogBytes { trimLog() }
        partialLine += output
        var lines = partialLine.components(separatedBy: .newlines)
        partialLine = lines.removeLast()
        return lines
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
