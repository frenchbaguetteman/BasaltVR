import Foundation
import BasaltBottleKit

/// Rules for the Library's Add Game sheet: a Windows game from GOG, itch.io,
/// or any installer, chosen by hand from a folder in a Basalt bottle.
public enum ManualGame {
    /// "Some Game" from `…/drive_c/GOG Games/Some Game/game.exe`. An exe
    /// directly in drive_c has no game folder, so it gives its own name.
    public static func suggestedName(for executable: URL) -> String {
        let folder = executable.deletingLastPathComponent().lastPathComponent
        if folder.isEmpty || folder == "/" || folder.lowercased() == "drive_c" {
            return executable.deletingPathExtension().lastPathComponent
        }
        return folder
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

    /// itch.io when the path says so (the itch app installs to `…\itch\apps`).
    public static func inferredSource(for executable: URL) -> LaunchSource {
        executable.path.localizedCaseInsensitiveContains("itch") ? .itch : .direct
    }

    /// Space-separated arguments. Quotes are not parsed.
    public static func arguments(from text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
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
