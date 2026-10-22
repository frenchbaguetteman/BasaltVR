import Foundation
import XCTest
import BasaltCore
@testable import BasaltManagerKit

/// Play page sessions (scripts/play.zsh) go to the same history as Stream page ones.
final class PlaySessionRecorderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func recorder(_ transport: PlayTransport = .auto,
                          _ quality: PlayQuality = .high) -> PlaySessionRecorder {
        PlaySessionRecorder(
            profileName: "half-life-alyx",
            options: PlayOptions(transport: transport, quality: quality),
            startedAt: start)
    }

    private var questLine: String {
        StreamReport.questLine(
            framesPerSecond: 72, averageLatencyMilliseconds: 50,
            maximumLatencyMilliseconds: 60, decodeMilliseconds: 4,
            decoderQueueMilliseconds: 1, vsyncQueueMilliseconds: 8)
    }

    func testStoppedWiFiSessionIsRecordedWithItsSettingsAndMetrics() throws {
        var recorder = recorder()
        recorder.apply(.start(profile: "half-life-alyx"))
        recorder.apply(.connection(.wifi))
        recorder.apply(.headsetReady)
        recorder.apply(.gameStart(profile: "half-life-alyx"), at: start.addingTimeInterval(30))
        recorder.apply(streamerLine: questLine)
        recorder.apply(streamerLine: "OpenXR runtime connected")
        recorder.requestStop()
        recorder.apply(.stopping)
        recorder.apply(.stopped)

        let record = try XCTUnwrap(recorder.finish(
            exitStatus: 130, lastError: nil, at: start.addingTimeInterval(90)))
        XCTAssertEqual(record.profileName, "half-life-alyx")
        XCTAssertEqual(record.outcome, .stopped)
        XCTAssertNil(record.failureReason)
        XCTAssertEqual(record.startedAt, start)
        XCTAssertEqual(record.streamingDuration, 60)
        XCTAssertEqual(record.settings.connection, .wifi)
        XCTAssertEqual(record.settings.megabits, PlayLaunchPlan.wifiHighMegabits)
        XCTAssertEqual(record.settings.resolution, .quality)
        XCTAssertEqual(record.metrics.fps.count, 1)
        XCTAssertEqual(record.metrics.latencyMilliseconds.average, 50)

        let store = SessionHistoryStore(dataRoot: try temporaryDirectory())
        let older = SessionRecord(profileName: "hello-xr", settings: StreamLaunchSettings())
        try store.append(older)
        let saved = try store.append(record)
        XCTAssertEqual(saved.map(\.id), [record.id, older.id])
        XCTAssertEqual(store.load().first?.outcome, .stopped)
    }

    func testStopBeforeTheGameStartsIsNotASession() {
        var recorder = recorder()
        recorder.apply(.connection(.usb))
        recorder.apply(.headsetWait)
        recorder.requestStop()
        recorder.apply(.stopped)
        XCTAssertNil(recorder.finish(exitStatus: 130, lastError: nil))
    }

    func testGameThatEndsOnItsOwnIsEnded() throws {
        var recorder = recorder(.usb, .normal)
        recorder.apply(.connection(.usb))
        recorder.apply(.gameStart(profile: "half-life-alyx"))
        recorder.apply(.gameEnded(status: 0))
        recorder.apply(.stopped)
        let record = try XCTUnwrap(recorder.finish(exitStatus: 0, lastError: nil))
        XCTAssertEqual(record.outcome, .ended)
        XCTAssertEqual(record.settings.connection, .wired)
        XCTAssertEqual(record.settings.resolution, .balanced)
        XCTAssertEqual(record.settings.megabits, 30)
    }

    func testStartupFailureIsRecordedWithItsMessage() throws {
        var recorder = recorder()
        recorder.apply(.connection(.wifi))
        recorder.apply(.fail(.wifiTimeout))
        recorder.apply(.stopped)
        let record = try XCTUnwrap(recorder.finish(exitStatus: 1, lastError: "timed out"))
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failureReason, PlayFailure.wifiTimeout.message)
        XCTAssertNil(record.streamingStartedAt)
        XCTAssertNotNil(record.endedAt)
    }

    func testUnexplainedNonZeroExitIsAFailure() throws {
        var recorder = recorder()
        recorder.apply(.gameStart(profile: "half-life-alyx"))
        let record = try XCTUnwrap(recorder.finish(exitStatus: 2, lastError: "Error: boom"))
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failureReason, "Error: boom")
    }

    func testAppLogIsNamedLikeAStreamPageLogAndIsCreated() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 18
        components.hour = 13; components.minute = 56; components.second = 5
        let date = try XCTUnwrap(Calendar.current.date(from: components))
        XCTAssertEqual(AppSessionLog.fileName(profileName: "Half-Life: Alyx", date: date),
                       "app-\(ProfileNaming.slug("Half-Life: Alyx"))-20261018-135605.log")

        let directory = try temporaryDirectory().appendingPathComponent("Logs")
        let handle = try XCTUnwrap(AppSessionLog.open(
            profileName: "half-life-alyx", in: directory, date: date))
        try handle.write(contentsOf: Data("hello\n".utf8))
        try handle.close()
        let file = directory.appendingPathComponent("app-half-life-alyx-20261018-135605.log")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello\n")
    }
}
