import Foundation

/// Deletes old BasaltVR logs from `~/Library/Logs/BasaltVR`, like
/// `basalt_prune_logs` in scripts/log-retention.zsh (play.zsh). Keep both in step.
///
/// Only regular files directly in the folder whose name is a BasaltVR log name
/// (`quest-*`, `streamer-*`, `runtime-*`, `game-*`, `steam-*`, `app-*`, `*.log`)
/// and that were last changed more than `keepDays` days ago are deleted.
/// Subfolders and symbolic links are never touched.
public enum LogRetention {
    public static let defaultKeepDays = 7
    static let prefixes = ["quest-", "streamer-", "runtime-", "game-", "steam-", "app-"]

    public static func isLogName(_ name: String) -> Bool {
        name.hasSuffix(".log") || prefixes.contains { name.hasPrefix($0) }
    }

    /// Returns the files it deleted. Errors are ignored: a log that cannot be
    /// deleted now is tried again at the next session.
    @discardableResult
    public static func pruneOldLogs(
        in directory: URL = PlayTools.logsDirectory(),
        keepDays: Int = defaultKeepDays,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [URL] {
        guard keepDays > 0,
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants])
        else { return [] }
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 24 * 60 * 60)
        var deleted: [URL] = []
        for entry in entries where isLogName(entry.lastPathComponent) {
            guard let file = try? entry.resourceValues(forKeys: Set(keys)),
                  file.isRegularFile == true, file.isSymbolicLink != true,
                  let modified = file.contentModificationDate, modified < cutoff
            else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil { deleted.append(entry) }
        }
        return deleted
    }
}
