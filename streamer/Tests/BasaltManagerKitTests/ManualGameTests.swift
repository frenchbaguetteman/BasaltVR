import XCTest
import BasaltBottleKit
@testable import BasaltManagerKit

final class ManualGameTests: XCTestCase {
    func testSuggestsTheExecutableFolderName() {
        XCTAssertEqual(ManualGame.suggestedName(for: URL(fileURLWithPath:
            "/bottles/pcvr/prefix/drive_c/GOG Games/Some Game/game.exe")), "Some Game")
        // An exe directly in drive_c has no game folder; use its own name.
        XCTAssertEqual(ManualGame.suggestedName(for: URL(fileURLWithPath:
            "/bottles/pcvr/prefix/drive_c/Launcher.exe")), "Launcher")
    }

    func testOnlyAcceptsExecutablesInstalledInThePrefix() throws {
        let temporary = try temporaryDirectory()
        let prefix = temporary.appendingPathComponent("pcvr/prefix", isDirectory: true)
        let game = prefix.appendingPathComponent("drive_c/GOG Games/Some Game/game.exe")
        try FileManager.default.createDirectory(
            at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x4d, 0x5a]).write(to: game)

        XCTAssertTrue(ManualGame.isInstalled(game, inPrefix: prefix))
        XCTAssertEqual(ManualGame.windowsPath(for: game, prefix: prefix),
                       #"C:\GOG Games\Some Game\game.exe"#)
        XCTAssertEqual(ManualGame.windowsPath(for: game.deletingLastPathComponent(), prefix: prefix),
                       #"C:\GOG Games\Some Game"#)

        // A sibling bottle whose name starts the same is not inside this one.
        let sibling = temporary.appendingPathComponent("pcvr/prefix2/drive_c/Game/game.exe")
        XCTAssertFalse(ManualGame.isInstalled(sibling, inPrefix: prefix))
        XCTAssertNil(ManualGame.windowsPath(for: sibling, prefix: prefix))
        // Downloads on the Mac must be installed into the bottle first.
        let download = temporary.appendingPathComponent("Downloads/setup_game.exe")
        XCTAssertFalse(ManualGame.isInstalled(download, inPrefix: prefix))
        // The prefix itself and files outside drive_c are not installed games.
        XCTAssertFalse(ManualGame.isInstalled(
            prefix.appendingPathComponent("drive_c"), inPrefix: prefix))
        XCTAssertFalse(ManualGame.isInstalled(
            prefix.appendingPathComponent("system.reg"), inPrefix: prefix))
    }

    func testInfersItchFromThePath() {
        XCTAssertEqual(ManualGame.inferredSource(for: URL(fileURLWithPath:
            "/p/drive_c/users/me/AppData/Roaming/itch/apps/Some Game/game.exe")), .itch)
        XCTAssertEqual(ManualGame.inferredSource(for: URL(fileURLWithPath:
            "/p/drive_c/Itch Games/Some Game/game.exe")), .itch)
        XCTAssertEqual(ManualGame.inferredSource(for: URL(fileURLWithPath:
            "/p/drive_c/GOG Games/Some Game/game.exe")), .direct)
    }

    func testSplitsArgumentsOnWhitespace() {
        XCTAssertEqual(ManualGame.arguments(from: "  -vr   --fullscreen\t-w 1920 "),
                       ["-vr", "--fullscreen", "-w", "1920"])
        XCTAssertEqual(ManualGame.arguments(from: " "), [])
    }

    func testProfileNamesAreUniqueSlugs() {
        XCTAssertEqual(ProfileNaming.slug("Some Game"), "some-game")
        XCTAssertEqual(ProfileNaming.slug("  Half-Life: Alyx!  "), "half-life-alyx")
        XCTAssertEqual(ProfileNaming.slug("***"), "game")
        // Profile names are ASCII only; accents fold, other letters are dropped.
        XCTAssertEqual(ProfileNaming.slug("Café Über"), "cafe-uber")
        XCTAssertEqual(ProfileNaming.slug("ゲーム"), "game")
        XCTAssertEqual(ProfileNaming.slug(String(repeating: "a", count: 80)).count, 56)

        XCTAssertEqual(ProfileNaming.unique("Some Game", existing: []), "some-game")
        XCTAssertEqual(ProfileNaming.unique("Some Game", existing: ["Some-Game"]), "some-game-2")
        XCTAssertEqual(ProfileNaming.unique("Some Game", existing: ["some-game", "some-game-2"]),
                       "some-game-3")
    }
}
