import Foundation
import BasaltBottleKit

/// Which Steam a Library session starts, matching `scripts/play.zsh`.
public enum SteamSessionPlan {
    /// True when the profile's own executable is the Steam client: the plain
    /// `steam` profile, or `steam.exe -applaunch ID` (except Beat Saber, which
    /// `BottleManager.profileLaunchCommand` turns into a direct game launch).
    public static func launchesSteamClient(_ profile: LaunchProfile) -> Bool {
        guard WineProcessOwnership.isSteamClient(profile.executable) else { return false }
        if profile.source == .steam,
           let index = profile.arguments.firstIndex(of: "-applaunch"),
           index + 1 < profile.arguments.count,
           profile.arguments[index + 1] == "620980" {
            return false
        }
        return true
    }

    /// play.zsh's `needs_steam_first`: a game launched directly needs a signed-in
    /// Steam first. A profile that launches Steam itself must not get a second
    /// one: its steam.exe would hand over to the first and exit at once, which
    /// ended the session a second after it started.
    public static func startsSteamFirst(_ profile: LaunchProfile) -> Bool {
        guard profile.source == .steam || profile.source == .bsmanager else { return false }
        return !launchesSteamClient(profile)
    }
}

/// Finds the programs of a running game, as `scripts/game-processes.zsh` does.
///
/// Some games start a second program and exit (The Lab's hub starts Robot
/// Repair), and Steam can hand over to another steam.exe. The session lasts while
/// such a program runs. Every Windows process is a macOS process whose command
/// line starts with its Windows image path, so a process belongs to the game
/// when that path is under the game's install folder. Drive letter, case, and
/// slash direction are ignored.
public struct GameProcessMatcher: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Programs under an install folder.
        case folder(marker: String, launched: String, strict: Bool)
        /// The Steam client (`steam.exe`), for a profile that is Steam itself.
        case steamClient
    }

    public let kind: Kind
    /// Folder name of the game, for messages.
    public let name: String

    /// The matcher for a session that launched `executable` (Windows path).
    /// Nil when there is nothing to follow after it exits.
    public init?(profile: LaunchProfile, launchedExecutable executable: String) {
        if let folder = Self.folder(executable: executable, gameRoot: profile.gameRoot) {
            self = folder
        } else if SteamSessionPlan.launchesSteamClient(profile),
                  !profile.arguments.contains("-applaunch") {
            kind = .steamClient
            name = "Steam"
        } else {
            return nil
        }
    }

    init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    /// `game_find_root`: the `steamapps\common\<Game>` folder of the game root,
    /// the game root itself, the `steamapps\common\<Game>` folder of the
    /// executable, then the executable's folder. Nil for a bare `steam.exe`.
    static func folder(executable: String, gameRoot: String?) -> GameProcessMatcher? {
        let marker: String
        let name: String
        var strict = true
        if let root = gameRoot, !root.isEmpty {
            if let steam = steamFolder(root) {
                (marker, name) = steam
            } else {
                let original = trimmedTrailingSeparator(backslashed(root))
                marker = original.lowercased() + "\\"
                name = lastComponent(original)
                strict = false
            }
        } else if let steam = steamFolder(executable) {
            (marker, name) = steam
        } else {
            let normalized = normalize(executable)
            guard normalized.contains("\\"), lastComponent(normalized) != "steam.exe" else {
                return nil
            }
            let original = backslashed(executable)
            let folder = String(original[..<original.lastIndex(of: "\\")!])
            marker = folder.lowercased() + "\\"
            name = lastComponent(folder)
            strict = false
        }
        let normalized = normalize(executable)
        let launched = normalized.range(of: marker).map {
            String(normalized[$0.upperBound...])
        } ?? ""
        return GameProcessMatcher(
            kind: .folder(marker: marker, launched: launched, strict: strict), name: name)
    }

    /// `game_processes` for one command line: the image path below the game
    /// folder, or nil when the process is not one of the game's other programs.
    public func match(_ command: String) -> String? {
        switch kind {
        case .steamClient:
            return WineProcessOwnership.isSteamClient(command) ? "steam.exe" : nil
        case .folder(let marker, let launched, let strict):
            let original = Self.backslashed(command)
            let lowered = original.lowercased()
            guard let range = lowered.range(of: marker) else { return nil }
            let offset = lowered.distance(from: lowered.startIndex, to: range.upperBound)
            let after = String(original.dropFirst(offset))
            guard let exe = after.lowercased().range(of: ".exe") else { return nil }
            let length = after.lowercased().distance(
                from: after.lowercased().startIndex, to: exe.upperBound)
            let relative = String(after.prefix(length))
            if relative.lowercased() == launched { return nil }
            if !strict, Self.lastComponent(relative.lowercased()).hasPrefix("steam") {
                return nil
            }
            return relative
        }
    }

    private static func steamFolder(_ path: String) -> (marker: String, name: String)? {
        let original = backslashed(path)
        let lowered = original.lowercased()
        let common = "\\steamapps\\common\\"
        guard let range = lowered.range(of: common), range.upperBound < lowered.endIndex else {
            return nil
        }
        let offset = lowered.distance(from: lowered.startIndex, to: range.upperBound)
        let rest = original.dropFirst(offset)
        let folder = rest.prefix { $0 != "\\" }
        return ("steamapps\\common\\" + folder.lowercased() + "\\", String(folder))
    }

    private static func backslashed(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "\\")
    }

    private static func normalize(_ path: String) -> String {
        backslashed(path).lowercased()
    }

    private static func trimmedTrailingSeparator(_ path: String) -> String {
        path.hasSuffix("\\") ? String(path.dropLast()) : path
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "\\").last.map(String.init) ?? path
    }
}

/// `game_wait_for_children` as a state machine, one observation per poll: wait
/// up to `grace` for another program of the game, then until none is left for
/// `gonePolls` polls in a row.
public struct GameProcessFollower: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// Nothing seen yet; still inside the grace period.
        case waiting
        /// The first program seen (its image path below the game folder).
        case started(String)
        case running
        case ended
    }

    public let gracePolls: Int
    public let gonePolls: Int
    private var polls = 0
    private var gone = 0
    private var seen = false

    public init(grace: TimeInterval = 10, poll: TimeInterval = 1, gonePolls: Int = 3) {
        gracePolls = max(1, Int(grace / poll) + 1)
        self.gonePolls = max(1, gonePolls)
    }

    public mutating func observe(_ found: [String]) -> Event {
        guard seen else {
            if let first = found.first {
                seen = true
                return .started(first)
            }
            polls += 1
            return polls >= gracePolls ? .ended : .waiting
        }
        if found.isEmpty {
            gone += 1
            return gone >= gonePolls ? .ended : .running
        }
        gone = 0
        return .running
    }
}
