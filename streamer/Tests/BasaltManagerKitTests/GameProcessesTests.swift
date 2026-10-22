import XCTest
import BasaltBottleKit
@testable import BasaltManagerKit

final class GameProcessesTests: XCTestCase {
    private func profile(
        _ executable: String, arguments: [String] = [], gameRoot: String? = nil,
        source: LaunchSource = .steam
    ) -> LaunchProfile {
        LaunchProfile(name: "p", bottleName: "pcvr", source: source,
                      executable: executable, arguments: arguments, gameRoot: gameRoot)
    }

    private let steamExe = #"C:\Program Files (x86)\Steam\steam.exe"#

    func testOnlyDirectGameLaunchesStartSteamFirst() {
        // The steam profile is Steam itself: a second steam.exe as the "game"
        // handed over to the first and exited 0, which ended the session.
        XCTAssertFalse(SteamSessionPlan.startsSteamFirst(
            profile(steamExe, arguments: ["-cef-disable-gpu-compositing"])))
        XCTAssertTrue(SteamSessionPlan.launchesSteamClient(
            profile(steamExe, arguments: ["-cef-disable-gpu-compositing"])))
        XCTAssertFalse(SteamSessionPlan.startsSteamFirst(
            profile(steamExe, arguments: ["-applaunch", "450390"])))
        // Beat Saber's -applaunch becomes a direct launch of Beat Saber.exe.
        XCTAssertTrue(SteamSessionPlan.startsSteamFirst(
            profile(steamExe, arguments: ["-applaunch", "620980"])))
        XCTAssertFalse(SteamSessionPlan.launchesSteamClient(
            profile(steamExe, arguments: ["-applaunch", "620980"])))
        XCTAssertTrue(SteamSessionPlan.startsSteamFirst(profile(
            #"C:\Program Files (x86)\Steam\steamapps\common\The Lab\TheLab\win64\TheLab.exe"#)))
        XCTAssertTrue(SteamSessionPlan.startsSteamFirst(profile(
            #"Z:\Users\me\BSManager\BSInstances\1.40\Beat Saber.exe"#, source: .bsmanager)))
        XCTAssertFalse(SteamSessionPlan.startsSteamFirst(
            profile(#"C:\Games\Game.exe"#, source: .direct)))
    }

    func testFollowsOtherProgramsOfTheGameFolder() throws {
        let lab = #"C:\Program Files (x86)\Steam\steamapps\common\The Lab\TheLab\win64\TheLab.exe"#
        let matcher = try XCTUnwrap(GameProcessMatcher(
            profile: profile(lab), launchedExecutable: lab))
        XCTAssertEqual(matcher.name, "The Lab")

        XCTAssertEqual(matcher.match(
            #"Z:\Users\me\Library\drive_c\Program Files (x86)\Steam\steamapps\common\the lab\RobotRepair\bin\win64\vr.exe -vr"#),
            #"RobotRepair\bin\win64\vr.exe"#)
        // The launched hub itself and other folders are not "other programs".
        XCTAssertNil(matcher.match(lab + " -vr"))
        XCTAssertNil(matcher.match(steamExe))
        XCTAssertNil(matcher.match(
            #"C:\Program Files (x86)\Steam\steamapps\common\Beat Saber\Beat Saber.exe"#))
        XCTAssertNil(matcher.match(
            #"C:\Program Files (x86)\Steam\steamapps\common\The Lab\readme.txt"#))
    }

    func testPlainFolderIgnoresSteamPrograms() throws {
        let game = #"C:\Games\Space\space.exe"#
        let matcher = try XCTUnwrap(GameProcessMatcher(
            profile: profile(game, source: .direct), launchedExecutable: game))
        XCTAssertEqual(matcher.name, "Space")
        XCTAssertEqual(matcher.match(#"C:\Games\Space\bin\server.exe"#), #"bin\server.exe"#)
        XCTAssertNil(matcher.match(#"C:\Games\Space\steamerrorreporter.exe"#))

        let rooted = try XCTUnwrap(GameProcessMatcher(
            profile: profile(game, gameRoot: #"C:\Games\"#, source: .direct),
            launchedExecutable: game))
        XCTAssertEqual(rooted.name, "Games")
        XCTAssertEqual(rooted.match(#"C:\Games\Other\x.exe"#), #"Other\x.exe"#)
    }

    func testSteamClientProfileFollowsSteamItself() throws {
        let steamProfile = profile(steamExe, arguments: ["-cef-disable-gpu-compositing"])
        let matcher = try XCTUnwrap(GameProcessMatcher(
            profile: steamProfile, launchedExecutable: steamExe))
        XCTAssertEqual(matcher.kind, .steamClient)
        XCTAssertEqual(matcher.match(steamExe + " -inhibitbootstrap"), "steam.exe")
        XCTAssertNil(matcher.match(
            #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe"#))

        // steam.exe -applaunch with no game root: nothing to follow (play.zsh).
        XCTAssertNil(GameProcessMatcher(
            profile: profile(steamExe, arguments: ["-applaunch", "450390"]),
            launchedExecutable: steamExe))
    }

    func testFollowerWaitsForAChildThenUntilItIsGone() {
        var follower = GameProcessFollower(grace: 2, poll: 1, gonePolls: 3)
        XCTAssertEqual(follower.observe([]), .waiting)
        XCTAssertEqual(follower.observe(["vr.exe"]), .started("vr.exe"))
        XCTAssertEqual(follower.observe([]), .running)
        XCTAssertEqual(follower.observe([]), .running)
        XCTAssertEqual(follower.observe(["vr.exe"]), .running)
        XCTAssertEqual(follower.observe([]), .running)
        XCTAssertEqual(follower.observe([]), .running)
        XCTAssertEqual(follower.observe([]), .ended)

        var nothing = GameProcessFollower(grace: 2, poll: 1, gonePolls: 3)
        XCTAssertEqual(nothing.observe([]), .waiting)
        XCTAssertEqual(nothing.observe([]), .waiting)
        XCTAssertEqual(nothing.observe([]), .ended)
    }
}
