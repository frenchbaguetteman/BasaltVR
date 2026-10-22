import Foundation
import AppKit
import AVFoundation
import BasaltCore
import BasaltManagerKit

/// The Play screen's model: one play.zsh session, the Quest status, and the
/// first-run checks with their one-click fixes.
@MainActor
final class PlayController: ObservableObject {
    @Published var options: PlayOptions {
        didSet { persistOptions() }
    }
    @Published private(set) var progress = PlayProgress()
    @Published private(set) var stats = PlayLiveStats()
    @Published private(set) var quest = QuestStatus()
    @Published private(set) var microphone = MicrophoneAccess.currentState()
    /// The last ~400 lines of play.zsh output, for the Details section.
    @Published private(set) var logLines = [String]()
    /// A fix that is running ("Installing ALVR…"), and the result of the last one.
    @Published private(set) var fixInProgress: String?
    @Published var fixMessage: String?
    @Published var selectedGameID: String? {
        didSet { UserDefaults.standard.set(selectedGameID, forKey: Self.selectedGameKey) }
    }

    private(set) var tools: PlayTools
    private var dataRoot: URL?
    private var runner: PlaySessionRunner?
    private var lastError: String?
    private var stopWaiters = [() -> Void]()
    private var checkingQuest = false
    /// The running session's history record and its app log
    /// (`app-<profile>-<time>.log`), like a Stream page session.
    private var recorder: PlaySessionRecorder?
    private var sessionLog: FileHandle?
    /// Receives the saved history after a Play session is recorded.
    var onHistoryChanged: (([SessionRecord]) -> Void)?
    private static let optionsKey = "BasaltVR.playOptions.v1"
    private static let selectedGameKey = "BasaltVR.playSelectedGame"

    init(tools: PlayTools, dataRoot: URL?) {
        self.tools = tools
        self.dataRoot = dataRoot
        if let data = UserDefaults.standard.data(forKey: Self.optionsKey),
           let decoded = try? JSONDecoder().decode(PlayOptions.self, from: data) {
            options = decoded
        } else {
            options = PlayOptions()
        }
        selectedGameID = UserDefaults.standard.string(forKey: Self.selectedGameKey)
    }

    var isActive: Bool { progress.isActive }

    func update(tools: PlayTools, dataRoot: URL?) {
        guard !isActive else { return }
        self.tools = tools
        self.dataRoot = dataRoot
    }

    func readiness(audioDevices: [GameAudioDevice]) -> [PlayReadinessItem] {
        PlayReadiness.items(
            quest: quest, transport: options.transport,
            audioDevices: audioDevices, microphone: microphone)
    }

    // MARK: Session

    func play(_ game: PlayGame) {
        guard !isActive else { return }
        selectedGameID = game.id
        stats = PlayLiveStats()
        logLines = []
        lastError = nil
        progress.begin(gameTitle: game.title)
        let plan = PlayLaunchPlan.make(
            profile: game.profileName, options: options, tools: tools,
            dataRoot: dataRoot, parentPID: getpid())
        recorder = PlaySessionRecorder(profileName: game.profileName, options: options)
        try? sessionLog?.close()
        sessionLog = AppSessionLog.open(profileName: game.profileName)
        appendLog("$ play.zsh \(plan.arguments.dropFirst().joined(separator: " "))")
        let runner = PlaySessionRunner(plan: plan) { [weak self] output in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(output) }
            }
        }
        do {
            try runner.start()
            self.runner = runner
        } catch {
            progress.finish(exitStatus: 1, lastError: error.localizedDescription)
            appendLog("Could not start play.zsh: \(error.localizedDescription)")
            finishSession(exitStatus: 1, lastError: error.localizedDescription)
        }
    }

    /// Stops the session; `completion` runs once everything is closed.
    func stop(completion: (() -> Void)? = nil) {
        guard isActive, let runner else {
            completion?()
            return
        }
        if let completion { stopWaiters.append(completion) }
        progress.requestStop()
        recorder?.requestStop()
        runner.stop()
    }

    private func handle(_ output: PlaySessionRunner.Output) {
        switch output {
        case .line(let text, let isError):
            appendLog(text)
            if isError, !text.trimmingCharacters(in: .whitespaces).isEmpty,
               !text.hasPrefix(" ") {
                lastError = text
            }
        case .event(let event):
            progress.apply(event)
            recorder?.apply(event)
            if case .fail(let reason) = event { appendLog("Failed: \(reason.message)") }
            if case .connection = event { refreshQuestSoon() }
        case .streamerLine(let line):
            stats.apply(streamerLine: line)
            progress.apply(streamerLine: line)
            recorder?.apply(streamerLine: line)
            if line.contains("ALVR headset disconnected") || line.contains("ALVR headset reconnected")
                || line.lowercased().hasPrefix("error:") {
                appendLog("streamer: " + line)
            }
        case .exited(let status):
            progress.finish(exitStatus: status, lastError: lastError)
            appendLog("play.zsh exited with status \(status)")
            finishSession(exitStatus: status, lastError: lastError)
            runner = nil
            let waiters = stopWaiters
            stopWaiters = []
            waiters.forEach { $0() }
            refreshQuestSoon()
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        try? sessionLog?.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Saves the session to history and closes its app log.
    private func finishSession(exitStatus: Int32, lastError: String?) {
        defer {
            try? sessionLog?.close()
            sessionLog = nil
        }
        guard let finished = recorder?.finish(exitStatus: exitStatus, lastError: lastError) else {
            recorder = nil
            return
        }
        recorder = nil
        guard let dataRoot else { return }
        do {
            onHistoryChanged?(try SessionHistoryStore(dataRoot: dataRoot).append(finished))
        } catch {
            appendLog("Could not save session history: \(error.localizedDescription)")
        }
    }

    // MARK: Quest status and fixes

    /// One look at adb through scripts/quest-check.zsh. Skipped during a session so the
    /// app never competes with play.zsh for the Quest.
    func refreshQuest() async {
        guard !isActive, !checkingQuest, fixInProgress == nil else { return }
        checkingQuest = true
        defer { checkingQuest = false }
        let result = await Self.run(tools.questCheckScript, environment: scriptEnvironment)
        if result.status == 0 {
            quest = QuestStatus.parse(result.output)
        } else {
            var failed = QuestStatus()
            failed.reason = result.output
            quest = failed
        }
        microphone = MicrophoneAccess.currentState()
    }

    private func refreshQuestSoon() {
        Task { await refreshQuest() }
    }

    func perform(_ fix: PlayReadinessItem.Fix) async {
        switch fix {
        case .installADB:
            await runFix("Installing the Android tools…", success: "The Android tools are installed.") {
                guard let brew = SetupInspector.findExecutable(named: "brew") else {
                    NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                    return (1, "Homebrew is missing. Install it from brew.sh, then try again.")
                }
                return await Self.run(brew, arguments: ["install", "android-platform-tools"],
                                      environment: self.scriptEnvironment)
            }
        case .installALVR:
            await runFix("Installing ALVR on the Quest…",
                         success: "ALVR is installed. On the Quest, open ALVR once (Library › Unknown Sources) and accept its permissions.") {
                await Self.run(self.tools.installClientScript, arguments: ["--download"],
                               environment: self.scriptEnvironment)
            }
        case .replaceALVR:
            await runFix("Replacing ALVR on the Quest…",
                         success: "ALVR \(QuestStatus.expectedALVRVersion) is installed. On the Quest, open ALVR once and accept its permissions.") {
                await Self.run(self.tools.installClientScript, arguments: ["--download", "--yes"],
                               environment: self.scriptEnvironment)
            }
        case .useWithoutCable, .reconnectWiFi:
            await runFix("Turning on Wi-Fi for the Quest…",
                         success: "Done. You can unplug the cable. After a Quest restart, plug it in once and press this again.") {
                await Self.run(self.tools.wirelessScript, environment: self.scriptEnvironment)
            }
        case .installBlackHole:
            openBlackHoleInstaller()
        case .openAudioMIDISetup:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
        case .askMicrophone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = MicrophoneAccess.currentState()
        case .openMicrophoneSettings:
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    private func runFix(
        _ title: String, success: String,
        _ operation: @escaping () async -> (status: Int32, output: String)
    ) async {
        guard !isActive, fixInProgress == nil else { return }
        fixInProgress = title
        fixMessage = nil
        let result = await operation()
        fixInProgress = nil
        if result.status == 0 {
            fixMessage = success
        } else {
            let lines = result.output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            fixMessage = lines.suffix(2).joined(separator: " ")
        }
        appendLog("[\(title)] " + result.output)
        await refreshQuest()
    }

    /// Installing BlackHole needs the Mac password, so it runs in Terminal where the
    /// user can type it. A .command file opens in Terminal without extra permissions.
    private func openBlackHoleInstaller() {
        let script = """
        #!/bin/zsh
        print "BasaltVR: installing BlackHole 2ch, so game sound reaches the headset."
        print "macOS asks for your Mac password. Type it and press Return (it stays hidden)."
        brew=$(command -v brew || ls /opt/homebrew/bin/brew /usr/local/bin/brew 2>/dev/null | head -n 1)
        if [[ -z $brew ]]; then
            print "Homebrew is missing. Install it from https://brew.sh, then press Install BlackHole again."
            exit 1
        fi
        if "$brew" install --cask blackhole-2ch; then
            print "Done. Go back to BasaltVR. Then set BlackHole 2ch to 48,000 Hz in Audio MIDI Setup."
        fi
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BasaltVR-install-blackhole.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
            fixMessage = "Terminal opened. Type your Mac password there. Then come back and press Check Again."
        } catch {
            fixMessage = "Open Terminal and run: \(PlayReadiness.blackHoleCommand)"
        }
    }

    private var scriptEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = PlayLaunchPlan.searchPath(environment["PATH"])
        environment["BASALT_REPO_ROOT"] = tools.repoRoot.path
        environment["BASALT_BIN_DIR"] = tools.binDirectory.path
        if let dataRoot { environment["BASALT_DATA_DIR"] = dataRoot.path }
        return environment
    }

    private static func run(
        _ executable: URL, arguments: [String] = [], environment: [String: String]
    ) async -> (status: Int32, output: String) {
        await Task.detached {
            // Output goes to a file, not a pipe: an adb server that the script starts
            // keeps running and would hold a pipe open forever.
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("BasaltVR-\(UUID().uuidString).out")
            defer { try? FileManager.default.removeItem(at: file) }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            do {
                FileManager.default.createFile(atPath: file.path, contents: nil)
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                process.standardOutput = handle
                process.standardError = handle
                try process.run()
                process.waitUntilExit()
                let output = (try? Data(contentsOf: file)) ?? Data()
                return (process.terminationStatus, String(decoding: output, as: UTF8.self))
            } catch {
                return (1, error.localizedDescription)
            }
        }.value
    }

    private func persistOptions() {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: Self.optionsKey)
        }
    }
}
