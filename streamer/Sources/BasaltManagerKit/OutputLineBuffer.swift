import Foundation

/// Turns the chunks read from one child-process pipe into whole, prefixed lines.
///
/// A pipe delivers whatever the child has written so far, and Wine writes one
/// line in several small pieces. Prefixing each chunk would scatter the prefix
/// through the lines and interleave stdout with stderr, so each pipe gets its
/// own buffer. Bytes are buffered and split on LF before decoding, so a
/// multibyte character cut by a chunk boundary is decoded whole.
public final class OutputLineBuffer: @unchecked Sendable {
    private let prefix: String
    private let lock = NSLock()
    private var pending = Data()

    public init(prefix: String) {
        self.prefix = prefix
    }

    /// Adds a chunk and returns the lines it completed, each with the prefix and
    /// without its line ending (LF or CRLF).
    public func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(chunk)
        var lines = [String]()
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(line(pending[pending.startIndex..<newline]))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    /// At end of output, returns the unfinished last line (with the prefix), if any.
    public func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let rest = line(pending[...])
        pending.removeAll()
        return rest
    }

    private func line(_ bytes: Data.SubSequence) -> String {
        let content = bytes.last == 0x0D ? bytes.dropLast() : bytes
        return prefix + String(decoding: content, as: UTF8.self)
    }
}
