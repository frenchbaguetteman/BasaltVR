import Foundation
import Darwin

/// Runs one play.zsh session as a child of the app and reports its output.
///
/// The app stays the responsible process for play.zsh and everything it starts, so the
/// streamer's BlackHole capture uses the app's Microphone permission. play.zsh owns the
/// cleanup (game, Steam, Wine, streamer, adb logcat, Mac audio output); `stop()` asks it
/// to run that cleanup with SIGTERM, the same path as Ctrl-C in Terminal. If the app dies,
/// play.zsh notices (BASALT_PLAY_PARENT_PID) and cleans up by itself.
public final class PlaySessionRunner: @unchecked Sendable {
    public enum Output: Equatable, Sendable {
        /// A human line from play.zsh (stdout or stderr), without the newline.
        case line(String, isError: Bool)
        case event(PlayEvent)
        /// A new line in the streamer log (stats, Quest disconnects).
        case streamerLine(String)
        /// play.zsh exited; always the last output.
        case exited(Int32)
    }

    public let plan: PlayLaunchPlan
    private let baseEnvironment: [String: String]
    private let handler: @Sendable (Output) -> Void
    private let queue = DispatchQueue(label: "org.basaltvr.play-session")
    private let process = Process()
    private var buffers = [ObjectIdentifier: Data]()
    private var streamerLog: FileHandle?
    private var tailURL: URL?
    private var streamerBuffer = Data()
    private var tailTimer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?
    private var readHandles = [FileHandle]()
    private var openPipes = 0
    private var exitStatus: Int32?
    private var started = false
    private var exited = false

    /// `handler` is called on a private serial queue, in order.
    public init(plan: PlayLaunchPlan,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                handler: @escaping @Sendable (Output) -> Void) {
        self.plan = plan
        self.baseEnvironment = baseEnvironment
        self.handler = handler
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    /// Do not call from the handler (it runs on the same queue).
    public var isRunning: Bool { queue.sync { started && !exited } }

    public func start() throws {
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.currentDirectory
        process.environment = plan.processEnvironment(base: baseEnvironment)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        // The handlers hold the runner strongly until play.zsh has exited, so a session
        // keeps reporting even if the caller lets go of the runner; finish() releases them.
        for (pipe, isError) in [(output, false), (error, true)] {
            let key = ObjectIdentifier(pipe)
            readHandles.append(pipe.fileHandleForReading)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                self.queue.async {
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        self.flush(key: key, isError: isError)
                        self.openPipes -= 1
                        if self.exitStatus != nil && self.openPipes == 0 { self.finish() }
                    } else {
                        self.consume(data, key: key, isError: isError)
                    }
                }
            }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            self.queue.async {
                self.exitStatus = status
                if self.openPipes == 0 {
                    self.finish()
                } else {
                    // A child that inherited the pipes (an adb server started by the
                    // session) can hold them open; do not wait for it.
                    self.queue.asyncAfter(deadline: .now() + 2) { self.finish() }
                }
            }
        }
        try queue.sync {
            openPipes = 2
            do {
                try process.run()
            } catch {
                releaseHandlers()
                throw error
            }
            started = true
        }
    }

    /// Asks play.zsh to shut everything down (SIGTERM, like Ctrl-C). If it is still
    /// running after `gracePeriod`, it and its process group are killed.
    public func stop(gracePeriod: TimeInterval = 120) {
        queue.async { [self] in
            guard started, !exited else { return }
            kill(process.processIdentifier, SIGTERM)
            guard killTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + gracePeriod)
            timer.setEventHandler { [weak self] in self?.forceKill() }
            killTimer = timer
            timer.resume()
        }
    }

    private func forceKill() {
        guard started, !exited else { return }
        let pid = process.processIdentifier
        handler(.line("play.zsh did not stop in time; forcing it.", isError: true))
        // Only its own process group (Foundation gives the child one), never ours.
        let group = getpgid(pid)
        if group > 1 && group == pid && group != getpgrp() { kill(-group, SIGKILL) }
        kill(pid, SIGKILL)
    }

    private func consume(_ data: Data, key: ObjectIdentifier, isError: Bool) {
        var buffer = buffers[key, default: Data()]
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            emit(line, isError: isError)
        }
        buffers[key] = buffer
    }

    private func flush(key: ObjectIdentifier, isError: Bool) {
        if let rest = buffers.removeValue(forKey: key), !rest.isEmpty {
            emit(String(decoding: rest, as: UTF8.self), isError: isError)
        }
    }

    private func emit(_ line: String, isError: Bool) {
        guard let event = PlayEvent.parse(line) else {
            handler(.line(line, isError: isError))
            return
        }
        handler(.event(event))
        if case .log(let kind, let path) = event, kind == "streamer" {
            startTailing(URL(fileURLWithPath: path))
        }
    }

    // play.zsh appends the streamer's output to its own log file; follow it.
    private func startTailing(_ url: URL) {
        tailTimer?.cancel()
        tailURL = url
        streamerLog = nil
        streamerBuffer.removeAll()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.readStreamerLog(url) }
        tailTimer = timer
        timer.resume()
    }

    private func readStreamerLog(_ url: URL) {
        if streamerLog == nil {
            streamerLog = try? FileHandle(forReadingFrom: url)
        }
        guard let handle = streamerLog,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        streamerBuffer.append(data)
        while let newline = streamerBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: streamerBuffer[streamerBuffer.startIndex..<newline],
                              as: UTF8.self)
            streamerBuffer.removeSubrange(streamerBuffer.startIndex...newline)
            handler(.streamerLine(line))
        }
    }

    private func releaseHandlers() {
        readHandles.forEach { $0.readabilityHandler = nil }
        readHandles = []
        process.terminationHandler = nil
    }

    private func finish() {
        guard !exited, let status = exitStatus else { return }
        releaseHandlers()
        if let timer = tailTimer, let url = tailURL {
            readStreamerLog(url)
            timer.cancel()
        }
        tailTimer = nil
        try? streamerLog?.close()
        streamerLog = nil
        killTimer?.cancel()
        killTimer = nil
        exited = true
        handler(.exited(status))
    }
}
