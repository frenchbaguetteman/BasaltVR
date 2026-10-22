import Foundation
import BasaltBottleKit
import BasaltCore

/// One game tile on the Play screen: a launch profile, named and drawn from the
/// Steam library in its bottle when possible.
public struct PlayGame: Identifiable, Equatable, Sendable {
    public var id: String { profileName }
    public let profileName: String
    public let title: String
    public let bottleName: String
    public let appID: String?
    /// Local Steam library art (`appcache/librarycache`), if Steam has it.
    public let artwork: URL?
    /// Verified on a Quest with this Mac setup (docs/COMPATIBILITY.md).
    public let isVerified: Bool

    public init(profileName: String, title: String, bottleName: String,
                appID: String?, artwork: URL?, isVerified: Bool) {
        self.profileName = profileName
        self.title = title
        self.bottleName = bottleName
        self.appID = appID
        self.artwork = artwork
        self.isVerified = isVerified
    }
}

public enum PlayLibrary {
    /// Steam app IDs played on the headset through play.zsh.
    public static let verifiedGames = ["450390": "The Lab", "620980": "Beat Saber"]

    /// Game tiles for every profile except the plain Steam client profile
    /// (`steam.exe` without `-applaunch`, used to sign in), verified games first.
    public static func games(profiles: [LaunchProfile], steamGames: [SteamGame]) -> [PlayGame] {
        profiles.filter { !isSteamClientOnly($0) }.map { profile in
            let appID = appID(for: profile)
            let folder = steamFolder(for: profile)
            let steamGame = steamGames.first { game in
                game.bottleOrigin == .managed && game.bottleName == profile.bottleName
                    && ((appID != nil && game.appID == appID)
                        || (folder != nil && game.installDirectory.lastPathComponent
                            .caseInsensitiveCompare(folder!) == .orderedSame))
            }
            let resolvedID = appID ?? steamGame?.appID
            let verifiedName = resolvedID.flatMap { verifiedGames[$0] }
            return PlayGame(
                profileName: profile.name,
                title: steamGame?.name ?? verifiedName ?? folder ?? displayName(profile.name),
                bottleName: profile.bottleName,
                appID: resolvedID,
                artwork: steamGame?.artwork,
                isVerified: verifiedName != nil)
        }.sorted {
            if $0.isVerified != $1.isVerified { return $0.isVerified }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// `-applaunch ID`, else the SteamAppId / SteamGameId variable.
    public static func appID(for profile: LaunchProfile) -> String? {
        if let index = profile.arguments.firstIndex(of: "-applaunch"),
           index + 1 < profile.arguments.count {
            return profile.arguments[index + 1]
        }
        return [profile.environment["SteamAppId"], profile.environment["SteamGameId"]]
            .compactMap { $0 }.first { !$0.isEmpty }
    }

    /// "The Lab" from `...\steamapps\common\The Lab\TheLab\win64\TheLab.exe`.
    public static func steamFolder(for profile: LaunchProfile) -> String? {
        for path in [profile.gameRoot, profile.executable].compactMap({ $0 }) {
            let normalized = path.replacingOccurrences(of: "/", with: "\\")
            guard let range = normalized.range(
                of: "\\steamapps\\common\\", options: .caseInsensitive) else { continue }
            let folder = normalized[range.upperBound...].prefix { $0 != "\\" }
            if !folder.isEmpty { return String(folder) }
        }
        return nil
    }

    public static func isSteamClientOnly(_ profile: LaunchProfile) -> Bool {
        let executable = profile.executable.replacingOccurrences(of: "/", with: "\\")
            .split(separator: "\\").last.map(String.init)?.lowercased()
        return executable == "steam.exe" && !profile.arguments.contains("-applaunch")
    }

    /// "the-lab" → "The Lab"
    static func displayName(_ profileName: String) -> String {
        profileName.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// What `scripts/quest-check.zsh` reports (one look at adb; read-only).
public struct QuestStatus: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ok
        case unauthorized
        case none
        case noADB = "no-adb"
        /// Not checked yet, or the check itself failed.
        case unknown
    }

    public struct ALVRPackage: Equatable, Sendable {
        public let name: String
        public let version: String
    }

    public enum ALVRState: Equatable, Sendable {
        /// No Quest in adb, so the app cannot look.
        case unknown
        case missing
        case ready
        case otherVersion(String)
    }

    public static let expectedALVRPackage = "alvr.client.stable"
    public static let expectedALVRVersion = "20.14.1"

    public var state = State.unknown
    public var link: PlayLink?
    public var serial: String?
    public var model: String?
    public var reason: String?
    public var savedIP: String?
    public var adbPath: String?
    public var alvrPackages = [ALVRPackage]()

    public init() {}

    public static func parse(_ output: String) -> QuestStatus {
        var status = QuestStatus()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals]
            let value = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            let present = value.isEmpty ? nil : value
            switch key {
            case "status": status.state = State(rawValue: value) ?? .unknown
            case "link": status.link = PlayLink(rawValue: value)
            case "serial": status.serial = present
            case "model": status.model = present
            case "reason": status.reason = present
            case "saved_ip": status.savedIP = present
            case "adb": status.adbPath = present
            case "alvr":
                let parts = value.split(separator: " ", maxSplits: 1)
                if let name = parts.first {
                    status.alvrPackages.append(ALVRPackage(
                        name: String(name),
                        version: parts.count > 1 ? String(parts[1]) : "unknown"))
                }
            default: break
            }
        }
        return status
    }

    public var alvr: ALVRState {
        guard state == .ok else { return .unknown }
        if alvrPackages.contains(where: {
            $0.name == Self.expectedALVRPackage && $0.version == Self.expectedALVRVersion
        }) { return .ready }
        if let other = alvrPackages.first { return .otherVersion(other.version) }
        return .missing
    }

    /// "Quest 3" from adb's "Quest_3".
    public var displayModel: String {
        guard let model, !model.isEmpty else { return "Your Quest" }
        return model.replacingOccurrences(of: "_", with: " ")
    }
}

/// One line of the "Before you play" card, with at most one safe fix.
public struct PlayReadinessItem: Identifiable, Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        case ready
        /// Playing works, but something is missing (for example game sound).
        case warning
        /// Play will fail until this is fixed.
        case blocking
        case unknown
    }

    public enum Fix: Equatable, Sendable {
        case installADB
        case installALVR
        case replaceALVR(installedVersion: String)
        case useWithoutCable
        case reconnectWiFi
        case installBlackHole
        case openAudioMIDISetup
        case askMicrophone
        case openMicrophoneSettings

        public var title: String {
            switch self {
            case .installADB: return "Install Android Tools"
            case .installALVR: return "Install ALVR"
            case .replaceALVR: return "Replace ALVR…"
            case .useWithoutCable: return "Use Without Cable"
            case .reconnectWiFi: return "Reconnect over Wi-Fi"
            case .installBlackHole: return "Install BlackHole…"
            case .openAudioMIDISetup: return "Open Audio MIDI Setup"
            case .askMicrophone: return "Allow Microphone…"
            case .openMicrophoneSettings: return "Open Privacy Settings"
            }
        }
    }

    public let id: String
    public let title: String
    public let detail: String
    public let level: Level
    public let fix: Fix?

    public init(id: String, title: String, detail: String, level: Level, fix: Fix? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.level = level
        self.fix = fix
    }
}

public enum PlayReadiness {
    public static let blackHoleName = "BlackHole 2ch"
    public static let blackHoleCommand = "brew install --cask blackhole-2ch"

    /// The first-run checks for the Play screen. Pure, so every combination is tested.
    public static func items(
        quest: QuestStatus, transport: PlayTransport,
        audioDevices: [GameAudioDevice], microphone: MicrophoneAccessState
    ) -> [PlayReadinessItem] {
        [questItem(quest, transport: transport), alvrItem(quest)]
            + audioItems(audioDevices, microphone: microphone)
    }

    static func questItem(_ quest: QuestStatus, transport: PlayTransport) -> PlayReadinessItem {
        let title = "Quest"
        switch quest.state {
        case .ok where quest.link == .usb:
            return PlayReadinessItem(
                id: "quest", title: title,
                detail: "\(quest.displayModel) is connected with the USB cable.",
                level: .ready, fix: .useWithoutCable)
        case .ok:
            return PlayReadinessItem(
                id: "quest", title: title,
                detail: transport == .usb
                    ? "\(quest.displayModel) is on Wi-Fi only. Plug in the cable, or choose Wi-Fi."
                    : "\(quest.displayModel) is connected over Wi-Fi.",
                level: transport == .usb ? .blocking : .ready)
        case .unauthorized:
            return PlayReadinessItem(
                id: "quest", title: title,
                detail: "Put on the headset and tap Allow for USB debugging.",
                level: .blocking)
        case .none:
            let wifiOK = transport != .usb
            let hint = wifiOK
                ? " Wi-Fi play still works: open ALVR on the Quest yourself."
                : ""
            if quest.savedIP != nil {
                return PlayReadinessItem(
                    id: "quest", title: title,
                    detail: "No Quest found. Plug in the USB cable, or reconnect over Wi-Fi." + hint,
                    level: wifiOK ? .warning : .blocking, fix: .reconnectWiFi)
            }
            return PlayReadinessItem(
                id: "quest", title: title,
                detail: "No Quest found. Turn it on and plug it in with the USB cable." + hint,
                level: wifiOK ? .warning : .blocking)
        case .noADB:
            return PlayReadinessItem(
                id: "quest", title: title,
                detail: "The Android tools (adb) are missing. BasaltVR needs them to find the Quest.",
                level: transport == .wifi ? .warning : .blocking, fix: .installADB)
        case .unknown:
            return PlayReadinessItem(
                id: "quest", title: title, detail: "Checking…", level: .unknown)
        }
    }

    static func alvrItem(_ quest: QuestStatus) -> PlayReadinessItem {
        let title = "ALVR on the Quest"
        let version = QuestStatus.expectedALVRVersion
        switch quest.alvr {
        case .ready:
            return PlayReadinessItem(
                id: "alvr", title: title, detail: "ALVR \(version) is installed.", level: .ready)
        case .missing:
            return PlayReadinessItem(
                id: "alvr", title: title,
                detail: "ALVR is not on the Quest. BasaltVR installs the checked ALVR \(version).",
                level: .blocking, fix: .installALVR)
        case .otherVersion(let installed):
            return PlayReadinessItem(
                id: "alvr", title: title,
                detail: "ALVR \(installed) is installed. BasaltVR needs ALVR \(version).",
                level: .warning, fix: .replaceALVR(installedVersion: installed))
        case .unknown:
            return PlayReadinessItem(
                id: "alvr", title: title,
                detail: "Connect the Quest to check ALVR.", level: .unknown)
        }
    }

    static func audioItems(
        _ devices: [GameAudioDevice], microphone: MicrophoneAccessState
    ) -> [PlayReadinessItem] {
        guard let blackHole = devices.first(where: { $0.name == blackHoleName }) else {
            return [PlayReadinessItem(
                id: "sound", title: "Game sound",
                detail: "Install BlackHole to hear the game in the headset. It needs your Mac password. Command: \(blackHoleCommand)",
                level: .warning, fix: .installBlackHole)]
        }
        var items = [PlayReadinessItem]()
        if blackHole.sampleRate > 0 && abs(blackHole.sampleRate - 48_000) > 1 {
            items.append(PlayReadinessItem(
                id: "sound", title: "Game sound",
                detail: "Set BlackHole 2ch to 48,000 Hz in Audio MIDI Setup (now \(Int(blackHole.sampleRate)) Hz).",
                level: .warning, fix: .openAudioMIDISetup))
        } else {
            items.append(PlayReadinessItem(
                id: "sound", title: "Game sound", detail: "BlackHole is ready.", level: .ready))
        }
        switch microphone {
        case .authorized:
            items.append(PlayReadinessItem(
                id: "microphone", title: "Microphone permission",
                detail: "Allowed. Game sound can reach the headset.", level: .ready))
        case .notDetermined:
            items.append(PlayReadinessItem(
                id: "microphone", title: "Microphone permission",
                detail: "macOS treats BlackHole as a microphone. Without this, game sound is silent.",
                level: .warning, fix: .askMicrophone))
        case .denied:
            items.append(PlayReadinessItem(
                id: "microphone", title: "Microphone permission",
                detail: "Turned off. Turn on BasaltVR in Privacy & Security › Microphone, then reopen BasaltVR.",
                level: .warning, fix: .openMicrophoneSettings))
        case .restricted:
            items.append(PlayReadinessItem(
                id: "microphone", title: "Microphone permission",
                detail: "A device-management profile blocks it, so game sound stays silent.",
                level: .warning))
        }
        return items
    }
}
