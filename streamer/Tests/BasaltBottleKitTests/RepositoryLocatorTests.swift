import XCTest
@testable import BasaltBottleKit

final class RepositoryLocatorTests: XCTestCase {
    func testWalksUpAndHonorsValidatedOverride() throws {
        let temporary = try temporaryDirectory()
        let nested = temporary.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary.appendingPathComponent("runtime"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: temporary.appendingPathComponent("streamer"),
            withIntermediateDirectories: true)
        try Data().write(to: temporary.appendingPathComponent("runtime/CMakeLists.txt"))
        try Data().write(to: temporary.appendingPathComponent("streamer/Package.swift"))
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertEqual(
            try RepositoryLocator.find(startingAt: nested, environment: [:]),
            temporary.standardizedFileURL)
        XCTAssertEqual(
            try RepositoryLocator.find(
                startingAt: URL(fileURLWithPath: "/"),
                environment: ["BASALT_REPO_ROOT": temporary.path]),
            temporary.standardizedFileURL)
        XCTAssertThrowsError(
            try RepositoryLocator.find(
                startingAt: URL(fileURLWithPath: "/"),
                environment: ["BASALT_REPO_ROOT": nested.path]))
        XCTAssertEqual(RepositoryLocator.layout(of: temporary), .source)
        XCTAssertNil(RepositoryLocator.layout(of: nested))
    }

    func testAcceptsPackagedSupportRoot() throws {
        let temporary = try temporaryDirectory()
        let runtime = temporary.appendingPathComponent(
            "runtime/build/bin", isDirectory: true)
        let docs = temporary.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: docs, withIntermediateDirectories: true)
        for path in [
            temporary.appendingPathComponent("BasaltVR.support.json"),
            runtime.appendingPathComponent("basalt_openxr.dll"),
            runtime.appendingPathComponent("basalt_openxr.json"),
            docs.appendingPathComponent("BOTTLES.md"),
        ] {
            try Data().write(to: path)
        }

        let nested = temporary.appendingPathComponent(
            "nested/release", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertEqual(
            try RepositoryLocator.find(startingAt: nested, environment: [:]),
            temporary.standardizedFileURL)
        XCTAssertEqual(RepositoryLocator.layout(of: temporary), .packaged)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BasaltVR-RepositoryLocator-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
