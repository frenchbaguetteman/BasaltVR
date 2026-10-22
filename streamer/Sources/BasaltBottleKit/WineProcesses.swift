import Foundation

/// Decides which macOS processes are Wine processes of one prefix.
///
/// `wineserver --kill` is not enough to empty a bottle. When the server dies
/// before its clients (it crashed during a Steam session's teardown: "wineserver
/// crashed, please enable coredumps"), the clients stay alive with parent 1 and
/// no server, and a second `wineserver --kill` finds nothing to kill. Those
/// orphans still hold files of their prefix, so ownership comes from open files:
///
/// - every Wine client maps shared memory from the prefix's server directory,
///   `/tmp/.wine-<uid>/server-<device>-<inode>/` (device and inode of the
///   prefix, in hexadecimal; Wine's own naming);
/// - a client that has not mapped it yet still holds a handle under the prefix
///   (its Windows current directory) and maps the Wine engine.
///
/// Other programs that only open a file in the prefix (Spotlight, an editor, a
/// shell whose current directory is there) never match, and nor do the
/// processes of another prefix, because both rules need this prefix.
public enum WineProcessOwnership {
    /// The server directory of `prefix`, as `/tmp/...` and as `/private/tmp/...`
    /// (the form `lsof` reports). Empty when the prefix does not exist.
    public static func serverDirectories(
        prefix: URL, userID: uid_t = getuid()
    ) -> [String] {
        var status = stat()
        guard stat(prefix.path, &status) == 0 else { return [] }
        let name = "server-" + String(UInt64(UInt32(bitPattern: status.st_dev)), radix: 16)
            + "-" + String(UInt64(status.st_ino), radix: 16)
        return ["/tmp", "/private/tmp"].map { "\($0)/.wine-\(userID)/\(name)" }
    }

    /// Process IDs in `lsof -F pn` output that belong to the prefix.
    public static func processIDs(
        lsofOutput: String, prefix: String, engineRoot: String?,
        serverDirectories: [String], excluding excluded: Set<Int32> = []
    ) -> [Int32] {
        let prefixPath = directoryPath(prefix)
        let enginePath = engineRoot.map(directoryPath)
        let serverPaths = serverDirectories.map(directoryPath)
        var order = [Int32]()
        var server = Set<Int32>()
        var inPrefix = Set<Int32>()
        var mapsEngine = Set<Int32>()
        var current: Int32?
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            if field == "p" {
                current = Int32(value)
                if let current { order.append(current) }
                continue
            }
            guard field == "n", let pid = current else { continue }
            let path = value + (value.hasSuffix("/") ? "" : "/")
            if serverPaths.contains(where: { path.hasPrefix($0) }) { server.insert(pid) }
            if path.hasPrefix(prefixPath) { inPrefix.insert(pid) }
            if let enginePath, path.hasPrefix(enginePath) { mapsEngine.insert(pid) }
        }
        var seen = Set<Int32>()
        return order.filter { pid in
            guard pid > 1, !excluded.contains(pid), seen.insert(pid).inserted else {
                return false
            }
            return server.contains(pid) || (inPrefix.contains(pid) && mapsEngine.contains(pid))
        }
    }

    /// The Windows image of a Wine command line, lowercased with backslashes:
    /// `c:\program files (x86)\steam\steam.exe` for
    /// `C:\Program Files (x86)\Steam\steam.exe -silent`. Nil when there is none.
    public static func windowsImage(of command: String) -> String? {
        let normalized = command.replacingOccurrences(of: "/", with: "\\").lowercased()
        guard let end = normalized.range(of: ".exe") else { return nil }
        return String(normalized[..<end.upperBound])
    }

    public static func isSteamClient(_ command: String) -> Bool {
        guard let image = windowsImage(of: command) else { return false }
        return image == "steam.exe" || image.hasSuffix("\\steam.exe")
    }

    /// No `standardizedFileURL`: it turns `/private/tmp` into `/tmp`, and lsof
    /// reports the `/private` form.
    private static func directoryPath(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}

/// The system calls behind bottle cleanup, replaceable in tests.
public protocol WineProcessControlling: Sendable {
    /// `lsof -F pn` output for `processIDs`, or for every process of this user.
    func openFiles(processIDs: [Int32]?) -> String
    /// Command line of every process, by process ID.
    func commandLines() -> [Int32: String]
    func send(_ signal: Int32, to processID: Int32)
    func isRunning(_ processID: Int32) -> Bool
    /// True while a wineserver holds the lock file in `serverDirectory`.
    func isServerRunning(serverDirectory: String) -> Bool
    func pause(_ seconds: TimeInterval)
}

public struct SystemWineProcessControl: WineProcessControlling {
    private let runner = ProcessBottleCommandRunner()

    public init() {}

    public func openFiles(processIDs: [Int32]?) -> String {
        var arguments = ["-n", "-P", "-w", "-F", "pn"]
        if let processIDs {
            guard !processIDs.isEmpty else { return "" }
            arguments += ["-p", processIDs.map(String.init).joined(separator: ",")]
        } else {
            arguments += ["-u", String(getuid())]
        }
        // lsof exits 1 when a listed process ended meanwhile; its output is
        // still complete for the others.
        return (try? runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: arguments,
            environment: [:], currentDirectory: nil).output) ?? ""
    }

    public func commandLines() -> [Int32: String] {
        guard let output = try? runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axww", "-o", "pid=,command="],
            environment: [:], currentDirectory: nil).output else { return [:] }
        var result = [Int32: String]()
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[..<space]) else { continue }
            result[pid] = String(trimmed[trimmed.index(after: space)...])
        }
        return result
    }

    public func send(_ signal: Int32, to processID: Int32) {
        _ = kill(processID, signal)
    }

    public func isRunning(_ processID: Int32) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }

    public func isServerRunning(serverDirectory: String) -> Bool {
        let descriptor = open(serverDirectory + "/lock", O_WRONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // The same probe wineserver uses: the running server write-locks it.
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        guard fcntl(descriptor, F_GETLK, &lock) == 0 else { return false }
        return lock.l_type != Int16(F_UNLCK)
    }

    public func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

/// What `BottleManager.shutDownBottle(launchedWith:)` did.
public struct BottleShutdownReport: Equatable, Sendable {
    /// Steam ran and closed by itself after `steam.exe -shutdown`.
    public var steamClosedGracefully = false
    /// Wine processes of the prefix that were still running after the server
    /// was gone, and were terminated one by one.
    public var leftoverProcessIDs = [Int32]()

    public init(steamClosedGracefully: Bool = false, leftoverProcessIDs: [Int32] = []) {
        self.steamClosedGracefully = steamClosedGracefully
        self.leftoverProcessIDs = leftoverProcessIDs
    }
}
