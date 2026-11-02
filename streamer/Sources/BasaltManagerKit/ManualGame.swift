import Foundation
import BasaltBottleKit

/// Rules for the Library's Add Game sheet: a Windows game from GOG, itch.io,
/// or any installer, chosen by hand from a folder in a Basalt bottle.
public enum ManualGame {
    /// "Some Game" from `…/drive_c/GOG Games/Some Game/game.exe`, and also
    /// from `…/Some Game/Binaries/Win64/Game-Win64-Shipping.exe` or
    /// `…/Some Game/game/bin/win64/game.exe`: build folders are skipped. An
    /// exe with no game folder above it gives its own name.
    public static func suggestedName(for executable: URL) -> String {
        for folder in foldersInDriveC(of: executable).reversed() {
            let name = folder.lowercased()
            if buildFolders.contains(name) { continue }
            if installFolders.contains(name) { break }
            return folder
        }
        return executable.deletingPathExtension().lastPathComponent
    }

    /// The game is installed in the bottle: the file is under the prefix's
    /// drive_c, so Wine sees it on C:.
    public static func isInstalled(_ executable: URL, inPrefix prefix: URL) -> Bool {
        windowsPath(for: executable, prefix: prefix) != nil
            && executable.resolvingSymlinksInPath().path != driveC(of: prefix).path
    }

    /// The `C:\…` path of a file or folder in the prefix's drive_c, or nil
    /// when it is somewhere else on the Mac.
    public static func windowsPath(for url: URL, prefix: URL) -> String? {
        let path = url.resolvingSymlinksInPath().path
        let driveC = driveC(of: prefix).path
        guard path == driveC || path.hasPrefix(driveC + "/") else { return nil }
        return BottleManager.winePath(
            for: URL(fileURLWithPath: path), prefix: prefix.resolvingSymlinksInPath())
    }

    /// itch.io when a folder inside drive_c is named for it: the itch app
    /// installs to `…\itch\apps`, and "Itch Games" counts too. Only the
    /// Windows path is read, so a Mac user or folder named "mitchell",
    /// "Twitch", or "Switch" does not count.
    public static func inferredSource(for executable: URL) -> LaunchSource {
        let isItch = foldersInDriveC(of: executable).contains { folder in
            folder.lowercased().split(whereSeparator: { !$0.isLetter }).first == "itch"
        }
        return isItch ? .itch : .direct
    }

    /// Space-separated arguments. Quotes are not parsed.
    public static func arguments(from text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Folders an Unreal, Source, or other engine puts between the game
    /// folder and its exe.
    private static let buildFolders: Set<String> = [
        "bin", "bin32", "bin64", "binaries", "win32", "win64", "x86", "x64",
        "x86_64", "amd64", "game", "release", "shipping",
    ]

    /// Folders that hold many games, so they never name one.
    private static let installFolders: Set<String> = [
        "program files", "program files (x86)", "gog games", "games", "apps",
    ]

    /// The folders between drive_c and the exe, outermost first. Without a
    /// drive_c in the path, every folder above the exe.
    private static func foldersInDriveC(of executable: URL) -> [String] {
        let folders = Array(executable.deletingLastPathComponent().pathComponents.dropFirst())
        guard let driveC = folders.lastIndex(where: { $0.lowercased() == "drive_c" }) else {
            return folders
        }
        return Array(folders[(driveC + 1)...])
    }

    private static func driveC(of prefix: URL) -> URL {
        prefix.resolvingSymlinksInPath().appendingPathComponent("drive_c", isDirectory: true)
    }
}

/// Launch profile names: lowercase slugs that `basaltctl` and the play
/// scripts accept, at most 56 characters.
public enum ProfileNaming {
    /// "Some Game" → "some-game". Accents fold ("Café" → "cafe"); other
    /// non-ASCII letters become separators.
    public static func slug(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        let folded = value.folding(options: [.diacriticInsensitive], locale: nil)
        let mapped = folded.lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        }
        let collapsed = String(mapped).replacingOccurrences(
            of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return String((collapsed.isEmpty ? "game" : collapsed).prefix(56))
    }

    /// The slug of `value`, with "-2", "-3", … added until no existing
    /// profile has the name (ignoring case).
    public static func unique(_ value: String, existing: [String]) -> String {
        let existingNames = Set(existing.map { $0.lowercased() })
        let base = slug(value)
        var name = base
        var suffix = 2
        while existingNames.contains(name.lowercased()) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        return name
    }
}
