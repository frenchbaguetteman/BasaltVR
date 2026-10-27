import Foundation
import BasaltBottleKit
import BasaltCore

/// Replaces personal and device identifiers in diagnostic text before it can
/// leave the Mac: the home folder and user name, email addresses, Steam IDs,
/// headset and Bonjour host names, MAC and IP addresses (loopback is kept),
/// long hex tokens such as the control-socket token, ADB serials, and
/// `account=`-style values. Replacements contain no quotes or backslashes,
/// and any quote a rule matches is put back, so redacting rendered JSON
/// keeps it valid.
public struct DiagnosticRedactor: Sendable {
    public let homeDirectory: String
    public let userName: String

    public init(homeDirectory: String = NSHomeDirectory(), userName: String = NSUserName()) {
        var home = homeDirectory
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        self.homeDirectory = home
        self.userName = userName
    }

    public func redact(_ text: String) -> String {
        var value = text
        let nameEnd = #"(?![A-Za-z0-9._-])"#
        if homeDirectory.count > 1, let home = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: homeDirectory) + nameEnd) {
            value = Self.replace(home, in: value, with: "~")
        }
        // macOS-style paths outside the home folder and Wine's
        // drive_c/users/<name>, including JSON-escaped backslashes.
        if !userName.isEmpty, let user = try? NSRegularExpression(
            pattern: #"(?i)([/\\]users[/\\]{1,2})"#
                + NSRegularExpression.escapedPattern(for: userName) + nameEnd) {
            value = Self.replace(user, in: value, with: "$1<user>")
        }
        for (expression, template) in Self.fixedRules {
            value = Self.replace(expression, in: value, with: template)
        }
        value = Self.replaceMatches(Self.ipv4, in: value) { address in
            address.hasPrefix("127.") || address == "0.0.0.0" ? nil : "<ipv4>"
        }
        value = Self.replaceMatches(Self.ipv6, in: value) { address in
            let bare = address.split(separator: "%").first.map(String.init) ?? address
            return bare == "::" || bare == "::1" ? nil : "<ipv6>"
        }
        value = Self.replace(Self.token, in: value, with: "<token>")
        // UUIDs (session IDs, temporary file names) identify nothing, but
        // their last group looks like a serial, so match and keep them whole.
        value = Self.replaceMatches(Self.uuidOrSerial, in: value) { match in
            match.contains("-") ? nil : "<serial>"
        }
        value = Self.replace(Self.account, in: value, with: "$1$2$3<redacted>$4")
        return value
    }

    /// The fixed patterns below are literals covered by DiagnosticsTests, so
    /// they compile once instead of on every redaction.
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// Applied before addresses: whole values whose parts could otherwise be
    /// mistaken for (or hide) an address.
    private static let fixedRules: [(NSRegularExpression, String)] = [
        (regex(#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#), "<email>"),
        (regex(#"\b7656119\d{10}\b"#), "<steamid>"),
        (regex(#"\[U:\d:\d+\]"#), "<steamid>"),
        (regex(#"(?i)\b[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.client\.alvr\b"#), "<headset>.client.alvr"),
        (regex(#"(?i)\b[A-Z0-9][A-Z0-9-]*\.local\b"#), "<host>.local"),
        (regex(#"(?i)(?<![0-9A-F:-])(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}(?![0-9A-F:-])"#), "<mac>"),
    ]

    private static let token = regex(#"(?i)\b[0-9A-F]{32,}\b"#)

    private static let ipv4 = regex(
        #"(?<![\w.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\w]|\.\d)"#)

    /// Full eight-group addresses, or compressed ones containing `::`.
    /// Shorter colon runs are left alone so timestamps never match.
    private static let ipv6 = regex(
        #"(?i)(?<![\w:])(?:(?:[0-9A-F]{1,4}:){7}[0-9A-F]{1,4}|(?:[0-9A-F]{1,4}(?::[0-9A-F]{1,4})*)?::(?:[0-9A-F]{1,4}(?::[0-9A-F]{1,4})*)?)(?:%[\w.]+)?(?![\w:])"#)

    /// A UUID, or an ADB/Quest serial: 10–20 upper-case letters and digits,
    /// both present.
    private static let uuidOrSerial = regex(
        #"(?i)\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b"#
            + "|" + #"(?-i:\b(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10,20}\b)"#)

    /// The value's quotes, plain or JSON-escaped, are captured and put back:
    /// a closing quote can also end the enclosing JSON string. Values stop at
    /// a lone backslash so JSON escapes such as `\n` stay intact.
    private static let account = regex(
        #"(?i)\b(account(?:_?name)?|user_?name|login|persona(?:_?name)?|steam_?id(?:64)?|serial(?:_?number)?)(\s*[:=]\s*)((?:\\?")?)(?:[^\s"',;\\]|\\\\)+((?:\\?")?)"#)

    private static func replace(
        _ expression: NSRegularExpression, in text: String, with template: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Replaces each match with `transform(match)`, or keeps it when nil.
    private static func replaceMatches(
        _ expression: NSRegularExpression, in text: String, transform: (String) -> String?
    ) -> String {
        var result = text
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let replacement = transform(String(result[range])) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

/// A structured snapshot of the Mac, setup, bottles, profiles, stream
/// settings, and recent sessions for bug reports. Build it from live state,
/// then render it with a redactor; the unredacted renderings stay internal.
public struct DiagnosticReport: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let maximumLogLines = 300
    public static let maximumRecentSessions = 10

    public struct Application: Codable, Equatable, Sendable {
        public var version: String
        public var build: String?
        /// Short commit of a source checkout; nil for packaged builds.
        public var sourceRevision: String?
        public var controlProtocol: Int

        public init(version: String, build: String?, sourceRevision: String?,
                    controlProtocol: Int = Int(RuntimeLink.protocolVersion)) {
            self.version = version
            self.build = build
            self.sourceRevision = sourceRevision
            self.controlProtocol = controlProtocol
        }

        public static func current(repoRoot: URL, bundle: Bundle = .main) -> Application {
            let info = bundle.infoDictionary ?? [:]
            return Application(
                version: info["CFBundleShortVersionString"] as? String ?? "source build",
                build: info["CFBundleVersion"] as? String,
                sourceRevision: SourceRevision.read(repository: repoRoot))
        }
    }

    public struct System: Codable, Equatable, Sendable {
        public var operatingSystem: String
        public var hardwareModel: String?
        public var chip: String?
        public var architecture: String?
        public var memoryGigabytes: Int
        public var processorCount: Int
        public var thermalState: String
        public var lowPowerMode: Bool

        public init(operatingSystem: String, hardwareModel: String?, chip: String?,
                    architecture: String?, memoryGigabytes: Int, processorCount: Int,
                    thermalState: String, lowPowerMode: Bool) {
            self.operatingSystem = operatingSystem
            self.hardwareModel = hardwareModel
            self.chip = chip
            self.architecture = architecture
            self.memoryGigabytes = memoryGigabytes
            self.processorCount = processorCount
            self.thermalState = thermalState
            self.lowPowerMode = lowPowerMode
        }

        public static func current() -> System {
            let info = ProcessInfo.processInfo
            return System(
                operatingSystem: "macOS " + info.operatingSystemVersionString
                    .replacingOccurrences(of: "Version ", with: ""),
                hardwareModel: sysctlString("hw.model"),
                chip: sysctlString("machdep.cpu.brand_string"),
                architecture: sysctlString("hw.machine"),
                memoryGigabytes: Int((Double(info.physicalMemory) / 1_073_741_824).rounded()),
                processorCount: info.processorCount,
                thermalState: label(for: info.thermalState),
                lowPowerMode: info.isLowPowerModeEnabled)
        }

        static func label(for state: ProcessInfo.ThermalState) -> String {
            switch state {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "unknown"
            }
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            let value = String(cString: buffer).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }

    public struct Check: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var status: String
        public var required: Bool
        public var detail: String
    }

    public struct Engine: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var supportsBasaltDXMT: Bool
    }

    public struct Bottle: Codable, Equatable, Sendable {
        public var name: String
        public var origin: String
        public var prefix: String
        public var engineID: String?
        public var dxmtInstalled: Bool?
        public var runtimeInstalled: Bool?
    }

    public struct Profile: Codable, Equatable, Sendable {
        public var name: String
        public var bottleName: String
        public var source: String
        public var executable: String
        public var arguments: [String]
        /// Variable names only: values may hold anything the user typed.
        public var environmentKeys: [String]
        public var hasCustomStreamSettings: Bool
    }

    public struct Session: Codable, Equatable, Sendable {
        public var state: String
        public var profileName: String?
        public var metrics: StreamMetricSummary?

        public init(state: String, profileName: String? = nil,
                    metrics: StreamMetricSummary? = nil) {
            self.state = state
            self.profileName = profileName
            self.metrics = metrics
        }
    }

    public var formatVersion: Int
    public var generatedAt: Date
    public var application: Application
    public var system: System
    public var setupChecks: [Check]
    public var engines: [Engine]
    public var bottles: [Bottle]
    public var profiles: [Profile]
    public var defaultStreamSettings: StreamLaunchSettings
    public var profileStreamSettings: [String: StreamLaunchSettings]
    public var currentSession: Session
    public var recentSessions: [SessionRecord]
    /// The end of the session log, or nil when the user left it out.
    public var logTail: [String]?

    public init(
        generatedAt: Date = Date(),
        application: Application,
        system: System,
        setupChecks: [SetupCheck],
        engines: [BottleEngine],
        bottles: [DiscoveredBottle],
        profiles: [LaunchProfile],
        defaultStreamSettings: StreamLaunchSettings,
        profileStreamSettings: [String: StreamLaunchSettings],
        currentSession: Session,
        recentSessions: [SessionRecord],
        log: String?
    ) {
        formatVersion = Self.currentFormatVersion
        self.generatedAt = generatedAt
        self.application = application
        self.system = system
        self.setupChecks = setupChecks.map {
            Check(id: $0.id, title: $0.title, status: $0.status.rawValue,
                  required: $0.required, detail: $0.detail)
        }
        self.engines = engines.map {
            Engine(id: $0.id, kind: $0.kind.rawValue, supportsBasaltDXMT: $0.supportsBasaltDXMT)
        }
        self.bottles = bottles.map {
            Bottle(name: $0.name, origin: $0.origin.rawValue, prefix: $0.prefix.path,
                   engineID: $0.managed?.engineID,
                   dxmtInstalled: $0.managed?.dxmtInstalled,
                   runtimeInstalled: $0.managed?.runtimeInstalled)
        }
        self.profiles = profiles.map {
            Profile(name: $0.name, bottleName: $0.bottleName, source: $0.source.rawValue,
                    executable: $0.executable, arguments: $0.arguments,
                    environmentKeys: $0.environment.keys.sorted(),
                    hasCustomStreamSettings: profileStreamSettings[$0.name] != nil)
        }
        let recentSessions = Array(recentSessions.prefix(Self.maximumRecentSessions))
        // Output device names can carry a person's name ("Ada's AirPods");
        // the report only says whether game audio goes through BlackHole.
        let audioDevices = Set(([defaultStreamSettings] + profileStreamSettings.values
                                + recentSessions.map(\.settings)).compactMap(\.audioDeviceName))
        self.defaultStreamSettings = Self.withAudioCategory(defaultStreamSettings)
        self.profileStreamSettings = profileStreamSettings.mapValues(Self.withAudioCategory)
        self.currentSession = currentSession
        self.recentSessions = recentSessions.map {
            var record = $0
            record.settings = Self.withAudioCategory(record.settings)
            return record
        }
        logTail = log.map { log in
            Self.tail(of: audioDevices.sorted { $0.count > $1.count }.reduce(log) {
                $1.isEmpty ? $0 : $0.replacingOccurrences(of: $1, with: Self.audioCategory($1))
            })
        }
    }

    static func audioCategory(_ deviceName: String) -> String {
        deviceName.localizedCaseInsensitiveContains("BlackHole") ? "BlackHole" : "<audio device>"
    }

    private static func withAudioCategory(_ settings: StreamLaunchSettings) -> StreamLaunchSettings {
        var settings = settings
        settings.audioDeviceName = settings.audioDeviceName.map(audioCategory)
        return settings
    }

    /// Pretty-printed JSON with every string passed through `redactor`.
    public func json(redactedWith redactor: DiagnosticRedactor) throws -> String {
        redactor.redact(try renderJSON())
    }

    /// GitHub-flavored Markdown, ready to paste into an issue, with every
    /// string passed through `redactor`.
    public func markdown(redactedWith redactor: DiagnosticRedactor) -> String {
        redactor.redact(renderMarkdown())
    }

    func renderJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    func renderMarkdown() -> String {
        let dates = ISO8601DateFormatter()
        var lines = [String]()

        lines += [
            "## BasaltVR diagnostic report", "",
            "Generated \(dates.string(from: generatedAt)) · report format \(formatVersion)", "",
            "| | |", "|---|---|",
            row("BasaltVR", [
                application.version,
                application.build.map { "build \($0)" },
                application.sourceRevision.map { "commit \($0)" },
                "control protocol v\(application.controlProtocol)",
            ]),
            row("macOS", [system.operatingSystem]),
            row("Mac", [
                system.hardwareModel, system.chip, system.architecture,
                "\(system.memoryGigabytes) GB", "\(system.processorCount) cores",
            ]),
            row("Power", [
                "thermal \(system.thermalState)",
                "Low Power Mode \(system.lowPowerMode ? "on" : "off")",
            ]),
        ]

        lines += ["", "### Setup", ""]
        lines += setupChecks.isEmpty ? ["No setup checks have run."] : setupChecks.map {
            "- [\($0.status == SetupCheckStatus.ready.rawValue ? "x" : " ")] "
                + "**\($0.title)**\($0.required ? "" : " (optional)") — \(flat($0.detail))"
        }

        lines += ["", "### Wine engines", ""]
        lines += engines.isEmpty ? ["None found."] : engines.map {
            "- `\($0.id)` (\($0.kind)\($0.supportsBasaltDXMT ? ", Basalt DXMT" : ""))"
        }

        lines += ["", "### Bottles", ""]
        if bottles.isEmpty {
            lines.append("None found.")
        } else {
            lines += ["| Bottle | Origin | Engine | DXMT | Runtime |", "|---|---|---|---|---|"]
            lines += bottles.map {
                "| \(cell($0.name)) | \($0.origin) | \(cell($0.engineID ?? "—")) "
                    + "| \(mark($0.dxmtInstalled)) | \(mark($0.runtimeInstalled)) |"
            }
        }

        lines += ["", "### Launch profiles", ""]
        if profiles.isEmpty {
            lines.append("None.")
        } else {
            lines += ["| Profile | Bottle | Source | Executable | Stream settings |",
                      "|---|---|---|---|---|"]
            lines += profiles.map {
                let arguments = $0.arguments.isEmpty ? "" : " " + $0.arguments.joined(separator: " ")
                return "| \(cell($0.name)) | \(cell($0.bottleName)) | \($0.source) "
                    + "| \(cell($0.executable + arguments)) "
                    + "| \($0.hasCustomStreamSettings ? "custom" : "default") |"
            }
        }

        lines += ["", "### Stream settings", "",
                  "- Default: \(Self.describe(defaultStreamSettings))"]
        lines += profileStreamSettings.sorted { $0.key < $1.key }.map {
            "- \($0.key): \(Self.describe($0.value))"
        }

        lines += ["", "### Current session", "", "- State: \(flat(currentSession.state))"]
        if let profile = currentSession.profileName { lines.append("- Profile: \(profile)") }
        if let metrics = currentSession.metrics, !metrics.isEmpty {
            lines.append("- Metrics: \(Self.describe(metrics))")
        }

        lines += ["", "### Recent sessions", ""]
        if recentSessions.isEmpty {
            lines.append("None recorded.")
        } else {
            lines += ["| Started | Profile | Settings | Streamed | Outcome | Metrics |",
                      "|---|---|---|---|---|---|"]
            lines += recentSessions.map { record in
                let outcome = record.outcome.map {
                    $0 == .failed ? "failed: \(record.failureReason ?? "unknown")" : $0.rawValue
                } ?? "unfinished"
                return "| \(dates.string(from: record.startedAt)) | \(cell(record.profileName)) "
                    + "| \(cell(Self.describe(record.settings))) "
                    + "| \(record.streamingDuration.map(Self.describe(duration:)) ?? "—") "
                    + "| \(cell(outcome)) | \(cell(Self.describe(record.metrics))) |"
            }
        }

        lines += ["", "### Session log", ""]
        if let logTail, !logTail.isEmpty {
            let fence = Self.fence(for: logTail)
            lines += ["<details><summary>Last \(logTail.count) lines</summary>", "",
                      fence + "text"]
            lines += logTail
            lines += [fence, "", "</details>"]
        } else {
            lines.append(logTail == nil ? "Not included." : "Empty.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Formatting

    static func describe(_ settings: StreamLaunchSettings) -> String {
        var parts = [
            settings.connection.label, "\(settings.fps) fps", "\(settings.megabits) Mbps",
            settings.resolution.label, "\(settings.latency.rawValue) latency",
        ]
        parts.append(settings.audioDeviceName.map { "audio \($0)" } ?? "no game audio")
        return parts.joined(separator: " · ")
    }

    static func describe(_ metrics: StreamMetricSummary) -> String {
        guard !metrics.isEmpty else { return "no reports" }
        var parts = [String]()
        if let average = metrics.fps.average, let low = metrics.fps.minimum {
            parts.append(String(format: "%.1f fps avg (min %.1f)", average, low))
        }
        if let share = metrics.lowFrameRateShare, share > 0 {
            parts.append(String(format: "%.0f%% below target", share * 100))
        }
        if let average = metrics.latencyMilliseconds.average,
           let high = metrics.latencyMilliseconds.maximum {
            parts.append(String(format: "%.0f ms avg (max %.0f)", average, high))
        }
        if let average = metrics.megabits.average {
            parts.append(String(format: "%.1f Mbps avg", average))
        }
        return parts.joined(separator: ", ")
    }

    static func describe(duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min \(seconds % 60) s" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }

    /// The last `maximumLogLines` lines without terminal color codes.
    static func tail(of log: String) -> [String] {
        let plain = log.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        var lines = plain.components(separatedBy: .newlines)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return Array(lines.suffix(maximumLogLines))
    }

    /// A backtick fence longer than any backtick run in the content.
    static func fence(for lines: [String]) -> String {
        var longest = 0
        for line in lines {
            var run = 0
            for character in line {
                run = character == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    private func row(_ title: String, _ values: [String?]) -> String {
        "| \(title) | \(cell(values.compactMap { $0 }.joined(separator: " · "))) |"
    }

    private func cell(_ value: String) -> String {
        flat(value).replacingOccurrences(of: "|", with: "\\|")
    }

    private func flat(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }

    private func mark(_ value: Bool?) -> String {
        value.map { $0 ? "yes" : "no" } ?? "—"
    }
}

/// Reads the checked-out commit of a source tree without running git.
public enum SourceRevision {
    public static func read(repository: URL, length: Int = 12) -> String? {
        guard let gitDirectory = gitDirectory(in: repository),
              let head = contents(of: gitDirectory.appendingPathComponent("HEAD"))
        else { return nil }
        let sha: String?
        if head.hasPrefix("ref:") {
            let reference = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let common = commonDirectory(for: gitDirectory)
            sha = [gitDirectory, common].lazy.compactMap {
                contents(of: $0.appendingPathComponent(reference))
            }.first ?? packedReference(reference, in: common)
        } else {
            sha = head
        }
        guard let sha, isObjectName(sha) else { return nil }
        return String(sha.prefix(length))
    }

    /// `.git` is a directory in a normal checkout and a `gitdir:` file in a
    /// worktree or submodule.
    private static func gitDirectory(in repository: URL) -> URL? {
        let dotGit = repository.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory)
        else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let link = contents(of: dotGit), link.hasPrefix("gitdir:") else { return nil }
        return resolve(link.dropFirst(7).trimmingCharacters(in: .whitespaces), against: repository)
    }

    private static func commonDirectory(for gitDirectory: URL) -> URL {
        guard let path = contents(of: gitDirectory.appendingPathComponent("commondir"))
        else { return gitDirectory }
        return resolve(path, against: gitDirectory)
    }

    private static func resolve(_ path: String, against directory: URL) -> URL {
        (path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : directory.appendingPathComponent(path, isDirectory: true)).standardizedFileURL
    }

    private static func packedReference(_ reference: String, in gitDirectory: URL) -> String? {
        guard let packed = contents(of: gitDirectory.appendingPathComponent("packed-refs"))
        else { return nil }
        for line in packed.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1)
            if fields.count == 2, fields[1] == reference { return String(fields[0]) }
        }
        return nil
    }

    private static func contents(of file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isObjectName(_ value: String) -> Bool {
        (40...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
}
