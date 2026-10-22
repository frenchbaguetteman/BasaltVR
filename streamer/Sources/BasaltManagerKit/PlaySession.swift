import Foundation

// The Play screen runs the headset-verified `scripts/play.zsh` as a child process instead
// of re-implementing its launch flow. These types build its command line, read its
// "@@basalt" event lines, and turn them into plain-language status for the app.

/// How the Quest is reached. `auto` is play.zsh's default: USB if a Quest is on the
/// cable, otherwise Wi-Fi.
public enum PlayTransport: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case usb
    case wifi

    public var id: Self { self }

    public var label: String {
        switch self {
        case .auto: return "Automatic"
        case .usb: return "USB cable"
        case .wifi: return "Wi-Fi"
        }
    }

    /// play.zsh's flag; `auto` has none.
    var flag: String? {
        switch self {
        case .auto: return nil
        case .usb: return "--usb"
        case .wifi: return "--wifi"
        }
    }
}

/// The two picture levels the app offers.
///
/// - `high`: play.zsh `--quality high --codec hevc` with Wi-Fi at 50 Mbps. USB: 1344x1408
///   per eye, 72 fps, 60 Mbps HEVC. Wi-Fi: 1344x1408, 50 Mbps HEVC. Both were verified on
///   the headset with The Lab (Wi-Fi on Wi-Fi 6, 5 GHz).
/// - `normal`: play.zsh `--quality normal` with its per-link codec. USB: 1152x1216, 30 Mbps
///   HEVC. Wi-Fi: 1344x1408, 20 Mbps H.264, for slower Wi-Fi.
public enum PlayQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case high

    public var id: Self { self }

    public var label: String { self == .high ? "High" : "Normal" }

    public var explanation: String {
        switch self {
        case .high:
            return "Sharp picture (HEVC). USB 60 Mbps, Wi-Fi 50 Mbps. Wi-Fi needs a fast Wi-Fi 6 router."
        case .normal:
            return "Lighter stream. USB 30 Mbps, Wi-Fi 20 Mbps. Use it if Wi-Fi stutters."
        }
    }
}

public struct PlayOptions: Codable, Equatable, Sendable {
    public var transport = PlayTransport.auto
    public var quality = PlayQuality.high
    /// Save `adb logcat` from the Quest for the session (play.zsh caps it at 200 MB).
    public var saveQuestLog = true

    public init(transport: PlayTransport = .auto, quality: PlayQuality = .high,
                saveQuestLog: Bool = true) {
        self.transport = transport
        self.quality = quality
        self.saveQuestLog = saveQuestLog
    }
}

/// Where the scripts and the built tools live. One copy only: the app uses the same
/// checkout (or packaged support folder) as `scripts/play.zsh` from Terminal, so the
/// Steam web helper shim and the bottle's runtime always come from one place.
public struct PlayTools: Equatable, Sendable {
    public var repoRoot: URL
    public var scriptsDirectory: URL
    /// Holds `basalt-streamer` and `basaltctl`.
    public var binDirectory: URL

    public init(repoRoot: URL, scriptsDirectory: URL? = nil, binDirectory: URL) {
        self.repoRoot = repoRoot
        self.scriptsDirectory = scriptsDirectory
            ?? repoRoot.appendingPathComponent("scripts", isDirectory: true)
        self.binDirectory = binDirectory
    }

    /// The app's own folder when it holds both tools (a self-contained bundle, or
    /// `swift run`), else the checkout's release build that play.zsh uses by default.
    public static func locate(
        repoRoot: URL, appExecutableDirectory: URL?,
        fileManager: FileManager = .default
    ) -> PlayTools {
        if let directory = appExecutableDirectory,
           ["basalt-streamer", "basaltctl"].allSatisfy({
               fileManager.isExecutableFile(
                   atPath: directory.appendingPathComponent($0).path)
           }) {
            return PlayTools(repoRoot: repoRoot, binDirectory: directory)
        }
        return PlayTools(
            repoRoot: repoRoot,
            binDirectory: repoRoot.appendingPathComponent(
                "streamer/.build/release", isDirectory: true))
    }

    public var playScript: URL { script("play.zsh") }
    public var questCheckScript: URL { script("quest-check.zsh") }
    public var wirelessScript: URL { script("quest-wireless.zsh") }
    public var installClientScript: URL { script("install-quest-client.zsh") }

    public func script(_ name: String) -> URL {
        scriptsDirectory.appendingPathComponent(name)
    }

    /// `~/Library/Logs/BasaltVR`, where play.zsh writes every log.
    public static func logsDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Logs/BasaltVR", isDirectory: true)
    }
}

/// The process that runs one Play session.
public struct PlayLaunchPlan: Equatable, Sendable {
    /// Wi-Fi Mbps for `high` (verified on the headset over Wi-Fi 6).
    public static let wifiHighMegabits = 50

    public var executable: URL
    public var arguments: [String]
    /// Set on top of the app's own environment (see `processEnvironment`).
    public var environment: [String: String]
    public var currentDirectory: URL

    /// Variables from the user's shell that would change the session behind the
    /// app's back. The app's choices are passed explicitly instead.
    static let clearedVariables = [
        "BASALT_TRANSPORT", "BASALT_QUALITY", "BASALT_CODEC", "BASALT_WIFI_MBPS",
        "ELECTRON_RUN_AS_NODE",
    ]

    public static func make(
        profile: String, options: PlayOptions, tools: PlayTools,
        dataRoot: URL?, parentPID: Int32
    ) -> PlayLaunchPlan {
        var arguments = [tools.playScript.path]
        if let flag = options.transport.flag { arguments.append(flag) }
        var environment = [
            "BASALT_PLAY_EVENTS": "1",
            "BASALT_PLAY_PARENT_PID": String(parentPID),
            "BASALT_REPO_ROOT": tools.repoRoot.path,
            "BASALT_BIN_DIR": tools.binDirectory.path,
        ]
        if let dataRoot { environment["BASALT_DATA_DIR"] = dataRoot.path }
        switch options.quality {
        case .high:
            arguments += ["--quality", "high", "--codec", "hevc"]
            environment["BASALT_WIFI_MBPS"] = String(wifiHighMegabits)
        case .normal:
            arguments += ["--quality", "normal"]
        }
        if !options.saveQuestLog { arguments.append("--no-log-quest") }
        arguments.append(profile)
        return PlayLaunchPlan(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: arguments,
            environment: environment,
            currentDirectory: tools.repoRoot)
    }

    /// The full child environment: the app's own, without the cleared variables, with
    /// a usable PATH (a Finder-launched app has only /usr/bin:/bin:/usr/sbin:/sbin),
    /// then this plan's values.
    public func processEnvironment(base: [String: String]) -> [String: String] {
        var result = base
        Self.clearedVariables.forEach { result.removeValue(forKey: $0) }
        result["PATH"] = Self.searchPath(base["PATH"])
        environment.forEach { result[$0.key] = $0.value }
        return result
    }

    /// Keeps the caller's order and adds the standard and Homebrew folders at the end.
    public static func searchPath(_ path: String?) -> String {
        var parts = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                          "/usr/sbin", "/sbin"] where !parts.contains(directory) {
            parts.append(directory)
        }
        return parts.joined(separator: ":")
    }
}

public enum PlayLink: String, Equatable, Sendable {
    case usb
    case wifi

    public var label: String { self == .usb ? "USB cable" : "Wi-Fi" }
}

/// Why play.zsh stopped early ("@@basalt fail CODE").
public enum PlayFailure: String, Equatable, Sendable {
    case build
    case profile
    case noADB = "no-adb"
    case questUnauthorized = "quest-unauthorized"
    case noUSBQuest = "no-usb-quest"
    case alvrMissing = "alvr-missing"
    case streamerRunning = "streamer-running"
    case streamerStopped = "streamer-stopped"
    case streamerTimeout = "streamer-timeout"
    case wifiTimeout = "wifi-timeout"
    case gameError = "game-error"
    case unknown

    public var message: String {
        switch self {
        case .build: return "The BasaltVR tools could not be built."
        case .profile: return "BasaltVR does not know this game."
        case .noADB: return "The Android tools (adb) are missing. Install them below."
        case .questUnauthorized:
            return "Put on your headset and tap Allow for USB debugging. Then press Play again."
        case .noUSBQuest:
            return "I cannot see your Quest on the USB cable. Plug it in, or choose Wi-Fi."
        case .alvrMissing: return "ALVR is not on your Quest. Install it below."
        case .streamerRunning:
            return "Another BasaltVR stream is already running. Stop it first."
        case .streamerStopped: return "The stream stopped unexpectedly. See Details."
        case .streamerTimeout:
            return "Your Quest did not connect in 3 minutes. Open ALVR on the Quest and press Play again."
        case .wifiTimeout:
            return "Your Quest did not connect over Wi-Fi in 3 minutes. Open ALVR on the Quest and use the same Wi-Fi as this Mac."
        case .gameError: return "The game stopped with an error. See Details."
        case .unknown: return "Something went wrong. See Details."
        }
    }
}

/// One "@@basalt" line from play.zsh (see `play_event` there).
public enum PlayEvent: Equatable, Sendable {
    case start(profile: String)
    case looking
    case wifiReconnect(ip: String)
    case connection(PlayLink)
    case quality(String)
    case log(kind: String, path: String)
    case alvrRestart
    case streamerStart
    case openALVR
    case steamStart
    case headsetWait
    case headsetReady
    case gameStart(profile: String)
    case gameChild(path: String)
    case gameEnded(status: Int32)
    case stopping
    case stopped
    case fail(PlayFailure)

    public static let prefix = "@@basalt "

    public static func parse(_ line: some StringProtocol) -> PlayEvent? {
        let text = String(line).trimmingCharacters(in: .newlines)
        guard text.hasPrefix(prefix) else { return nil }
        let body = text.dropFirst(prefix.count)
        let name = body.prefix { $0 != " " }
        let rest = body.dropFirst(name.count).drop { $0 == " " }
        let value = String(rest)
        switch name {
        case "start": return .start(profile: value)
        case "looking": return .looking
        case "wifi-reconnect": return .wifiReconnect(ip: value)
        case "connection": return PlayLink(rawValue: value).map(PlayEvent.connection)
        case "quality": return .quality(value)
        case "log":
            let kind = rest.prefix { $0 != " " }
            let path = rest.dropFirst(kind.count).drop { $0 == " " }
            guard !kind.isEmpty, !path.isEmpty else { return nil }
            return .log(kind: String(kind), path: String(path))
        case "alvr-restart": return .alvrRestart
        case "streamer-start": return .streamerStart
        case "open-alvr": return .openALVR
        case "steam-start": return .steamStart
        case "headset-wait": return .headsetWait
        case "headset-ready": return .headsetReady
        case "game-start": return .gameStart(profile: value)
        case "game-child": return .gameChild(path: value)
        case "game-ended": return .gameEnded(status: Int32(value) ?? 0)
        case "stopping": return .stopping
        case "stopped": return .stopped
        case "fail": return .fail(PlayFailure(rawValue: value) ?? .unknown)
        default: return nil
        }
    }
}

/// The Play screen's state, built only from play.zsh's events, the streamer's log, and
/// the process exit. Every headline is a plain sentence for a tired player.
public struct PlayProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case preparing
        case connecting
        case starting
        case playing
        case reconnecting
        case stopping
        case finished
        case failed
    }

    public private(set) var phase = Phase.idle
    public private(set) var headline = "Ready to play"
    public private(set) var detail = "Pick a game and press Play."
    public private(set) var gameTitle: String
    public private(set) var link: PlayLink?
    public private(set) var qualitySummary: String?
    public private(set) var streamerLog: URL?
    public private(set) var gameLog: URL?
    public private(set) var questLog: URL?
    public private(set) var failure: PlayFailure?
    /// The second program a game started (The Lab → Robot Repair), for the detail line.
    public private(set) var childProgram: String?
    public private(set) var stopRequested = false
    private var gameStarted = false
    private var gameEnded = false
    private var steamStarting = false

    public init(gameTitle: String = "") {
        self.gameTitle = gameTitle
    }

    /// True from Play until the session has fully shut down.
    public var isActive: Bool {
        switch phase {
        case .preparing, .connecting, .starting, .playing, .reconnecting, .stopping:
            return true
        case .idle, .finished, .failed:
            return false
        }
    }

    public mutating func begin(gameTitle: String) {
        self = PlayProgress(gameTitle: gameTitle)
        set(.preparing, "Looking for your Quest…", "Turn the Quest on. USB is used when the cable is in.")
    }

    public mutating func requestStop() {
        guard isActive else { return }
        stopRequested = true
        if phase != .stopping {
            set(.stopping, "Stopping…", "Closing the game, Steam, and the stream. This can take a minute.")
        }
    }

    public mutating func apply(_ event: PlayEvent) {
        switch event {
        case .start, .looking:
            guard !stopRequested, phase == .preparing else { return }
            set(.preparing, "Looking for your Quest…", detail)
        case .wifiReconnect:
            guard !stopRequested else { return }
            set(.preparing, "Looking for your Quest on Wi-Fi…", "Turn the Quest on.")
        case .connection(let value):
            link = value
            guard !stopRequested else { return }
            set(.preparing, value == .usb ? "Quest found on the USB cable" : "Using Wi-Fi",
                value == .usb ? "Getting ready…" : "Keep the Quest and this Mac on the same Wi-Fi.")
        case .quality(let text):
            qualitySummary = text
        case .log(let kind, let path):
            let url = URL(fileURLWithPath: path)
            switch kind {
            case "streamer": streamerLog = url
            case "game": gameLog = url
            case "quest": questLog = url
            default: break
            }
        case .alvrRestart:
            guard !stopRequested else { return }
            set(.preparing, "Getting ALVR ready on your Quest…", "This takes about 10 seconds.")
        case .streamerStart, .headsetWait:
            guard !stopRequested, !gameStarted else { return }
            set(.connecting, "Put on your headset", connectingDetail)
        case .openALVR:
            guard !stopRequested, !gameStarted else { return }
            set(.connecting, "Put on your headset", connectingDetail)
        case .steamStart:
            steamStarting = true
            guard !stopRequested, phase == .connecting else { return }
            set(.connecting, headline, connectingDetail)
        case .headsetReady:
            guard !stopRequested else { return }
            set(.starting, "Headset connected", "Starting \(gameTitle)…")
        case .gameStart:
            gameStarted = true
            guard !stopRequested else { return }
            set(.starting, "Starting \(gameTitle)…",
                "Keep the headset on. The game opens in about 30 seconds.")
        case .gameChild(let path):
            childProgram = Self.programName(path)
            guard !stopRequested else { return }
            set(.playing, "Playing \(gameTitle)", "\(childProgram ?? "The next part") is running.")
        case .gameEnded(let status):
            gameEnded = status == 0
            guard !stopRequested, phase != .failed else { return }
            set(.stopping, "The game ended", "Closing Steam and the stream…")
        case .stopping:
            if phase == .failed {
                detail = "Closing Steam and the stream…"
            } else if !gameEnded && !stopRequested {
                set(.stopping, "Stopping…", "Closing the game, Steam, and the stream.")
            } else if phase != .stopping {
                set(.stopping, headline, "Closing Steam and the stream…")
            }
        case .stopped:
            finishCleanly()
        case .fail(let reason):
            failure = reason
            guard !stopRequested else { return }
            set(.failed, reason.message, "")
        }
    }

    /// One line of the streamer's own log: the game's OpenXR connection and Quest
    /// disconnects/reconnects (the streamer survives them).
    public mutating func apply(streamerLine line: some StringProtocol) {
        guard !stopRequested, phase != .failed, phase != .finished, phase != .stopping else { return }
        if line.contains("ALVR headset disconnected") {
            set(.reconnecting, "Quest disconnected — reconnecting…",
                gameStarted
                    ? "Put the headset back on, or open ALVR on it. The game keeps running."
                    : "Put the headset back on, or open ALVR on it.")
        } else if line.contains("ALVR headset reconnected") {
            if gameStarted {
                set(.playing, "Playing \(gameTitle)", "The Quest is back.")
            } else {
                set(.connecting, "Put on your headset", connectingDetail)
            }
        } else if line.contains("OpenXR runtime connected")
                    || line.contains("OpenXR runtime: a new game session replaced") {
            guard gameStarted else { return }
            set(.playing, "Playing \(gameTitle)",
                childProgram.map { "\($0) is running." } ?? "Have fun! Press Stop when you are done.")
        }
    }

    /// The play.zsh process exited. `lastError` is its last stderr line, if any.
    public mutating func finish(exitStatus: Int32, lastError: String?) {
        if phase == .failed {
            if detail.hasPrefix("Closing") { detail = "" }
            return
        }
        if stopRequested || exitStatus == 0 {
            finishCleanly()
            return
        }
        failure = failure ?? .unknown
        set(.failed, "Something went wrong",
            lastError.map { "\($0) See Details." } ?? "See Details for the log.")
    }

    private mutating func finishCleanly() {
        if phase == .failed {
            if detail.hasPrefix("Closing") { detail = "" }
            return
        }
        if stopRequested {
            set(.finished, "Stopped", "Everything is closed. Press Play to start again.")
        } else if gameEnded {
            set(.finished, "The game ended", "Everything is closed. Press Play to start again.")
        } else {
            set(.finished, "Done", "Everything is closed. Press Play to start again.")
        }
    }

    private var connectingDetail: String {
        var text = link == .wifi
            ? "Open ALVR on your Quest if it is not open. It connects by itself."
            : "ALVR connects by itself. Tap nothing in ALVR."
        if steamStarting { text += " Steam is starting on this Mac." }
        return text
    }

    private mutating func set(_ phase: Phase, _ headline: String, _ detail: String) {
        self.phase = phase
        self.headline = headline
        self.detail = detail
    }

    /// "RobotRepair\bin\win64\vr.exe" → "RobotRepair"; "SecretShop.exe" → "SecretShop".
    static func programName(_ path: String) -> String {
        let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        guard let first = parts.first else { return path }
        let name = parts.count > 1 ? first : first.split(separator: ".").first ?? first
        return String(name)
    }
}

/// Live numbers for the Play screen, from the streamer's report lines.
public struct PlayLiveStats: Equatable, Sendable {
    public private(set) var framesPerSecond: Double?
    public private(set) var latencyMilliseconds: Double?
    public private(set) var megabits: Double?

    public init() {}

    /// Returns true when the line carried a number.
    @discardableResult
    public mutating func apply(streamerLine line: String) -> Bool {
        guard let sample = StreamLogMetricsParser.parse(line: line) else { return false }
        if let fps = sample.fps { framesPerSecond = fps }
        if let latency = sample.latencyMilliseconds { latencyMilliseconds = latency }
        if let rate = sample.megabits { megabits = rate }
        return true
    }

    public var isEmpty: Bool {
        framesPerSecond == nil && latencyMilliseconds == nil && megabits == nil
    }
}
