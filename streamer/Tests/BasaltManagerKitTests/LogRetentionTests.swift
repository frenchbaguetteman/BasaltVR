import XCTest
@testable import BasaltManagerKit

final class LogRetentionTests: XCTestCase {
    func testDeletesOnlyOldBasaltLogsDirectlyInTheFolder() throws {
        let root = try temporaryDirectory()
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: logs.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-8 * 24 * 3600)
        let recent = now.addingTimeInterval(-6 * 24 * 3600)

        func make(_ url: URL, _ date: Date) throws {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("x".utf8)))
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let oldNames = ["quest-1.log", "streamer-1.log", "runtime-1.log", "game-1.log",
                        "steam-1.log", "app-steam-1.log", "build-1.log", "quest-1.txt"]
        for name in oldNames { try make(logs.appendingPathComponent(name), old) }
        try make(logs.appendingPathComponent("game-new.log"), recent)
        try make(logs.appendingPathComponent("notes.txt"), old)
        try make(logs.appendingPathComponent("sub/game-old.log"), old)
        let target = outside.appendingPathComponent("game-old.log")
        try make(target, old)
        try fm.createSymbolicLink(
            at: logs.appendingPathComponent("game-link.log"), withDestinationURL: target)

        let deleted = LogRetention.pruneOldLogs(in: logs, now: now)

        XCTAssertEqual(Set(deleted.map(\.lastPathComponent)), Set(oldNames))
        let left = try fm.contentsOfDirectory(atPath: logs.path).sorted()
        XCTAssertEqual(left, ["game-link.log", "game-new.log", "notes.txt", "sub"])
        XCTAssertTrue(fm.fileExists(atPath: logs.appendingPathComponent("sub/game-old.log").path))
        XCTAssertTrue(fm.fileExists(atPath: target.path))
    }

    func testMissingFolderOrSymlinkedFolderDoesNothing() throws {
        let root = try temporaryDirectory()
        XCTAssertEqual(LogRetention.pruneOldLogs(in: root.appendingPathComponent("none")), [])
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("game-1.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(LogRetention.pruneOldLogs(in: link), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
