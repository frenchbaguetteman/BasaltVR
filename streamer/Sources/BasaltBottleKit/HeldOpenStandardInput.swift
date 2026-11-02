import Foundation
import Darwin

/// An empty standard input that stays open while a game runs.
///
/// Khronos hello_xr waits for a key press on a thread and quits when stdin reaches end
/// of file. `/dev/null` is end of file at once, so a game started with it quits before
/// its first frame. This gives the child the read end of a pipe. Only the launcher holds
/// the write end (close-on-exec, so no child inherits it), and nothing is ever written.
/// The write end closes when the child exits, when `close()` is called, or when the
/// launcher dies, so the game sees end of file only when the session is over.
/// Real games ignore stdin.
public final class HeldOpenStandardInput: @unchecked Sendable {
    private let lock = NSLock()
    private var writeDescriptor: Int32
    private var exitSource: DispatchSourceProcess?

    private init(writeDescriptor: Int32) {
        self.writeDescriptor = writeDescriptor
    }

    deinit {
        if writeDescriptor >= 0 { Darwin.close(writeDescriptor) }
    }

    /// Sets the pipe as `process.standardInput` (replacing any earlier value), runs the
    /// process, and holds the write end until the process exits. The returned object
    /// keeps itself alive until then; keep it only to call `close()` earlier.
    @discardableResult
    public static func run(_ process: Process) throws -> HeldOpenStandardInput {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw BottleToolError(
                "Could not create the game's standard input: \(String(cString: strerror(errno)))")
        }
        // posix_spawn's dup2 onto fd 0 clears close-on-exec for the child's copy only.
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        let readEnd = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let input = HeldOpenStandardInput(writeDescriptor: descriptors[1])
        process.standardInput = readEnd
        do {
            try process.run()
        } catch {
            try? readEnd.close()
            input.close()
            throw error
        }
        // The child has its own copy as fd 0.
        try? readEnd.close()
        input.closeWhenExits(process)
        return input
    }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writeDescriptor >= 0
    }

    /// Closes the write end: the child sees end of file. Safe to call more than once.
    public func close() {
        lock.lock()
        let descriptor = writeDescriptor
        let source = exitSource
        writeDescriptor = -1
        exitSource = nil
        lock.unlock()
        source?.cancel()
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    private func closeWhenExits(_ process: Process) {
        let source = DispatchSource.makeProcessSource(
            identifier: process.processIdentifier, eventMask: .exit,
            queue: .global(qos: .utility))
        // The handler holds self until the child exits; close() cancels the source.
        source.setEventHandler { self.close() }
        lock.lock()
        exitSource = source
        lock.unlock()
        source.resume()
        // The child may have exited (and been reaped) before the source was registered.
        if !process.isRunning { close() }
    }
}
