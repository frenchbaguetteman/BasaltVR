import XCTest
@testable import BasaltManagerKit
import BasaltCore

final class StreamHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reports(fps values: [Double], endingAt end: Date? = nil) -> [StreamMetricSample] {
        let end = end ?? now
        return values.enumerated().map { index, value in
            StreamMetricSample(
                date: end.addingTimeInterval(TimeInterval(index - values.count + 1)), fps: value)
        }
    }

    private func kinds(_ issues: [StreamHealthIssue]) -> [StreamHealthIssue.Kind] {
        issues.map(\.kind)
    }

    func testHealthyStreamHasNoIssues() {
        var settings = StreamLaunchSettings()
        settings.fps = 72
        let samples = reports(fps: [72, 71.8, 72, 70.5, 72, 71.9])
            + [StreamMetricSample(date: now, latencyMilliseconds: 52)]
        XCTAssertEqual(StreamHealthAdvisor.evaluate(samples: samples, settings: settings, now: now), [])
        XCTAssertEqual(StreamHealthAdvisor.evaluate(samples: [], settings: settings, now: now), [])
    }

    func testFlagsSustainedLowFrameRateWithASettingsSuggestion() throws {
        var settings = StreamLaunchSettings()
        settings.fps = 72
        settings.resolution = .quality
        // One dip is ignored; a sustained drop is not.
        let dip = reports(fps: [72, 72, 40, 72, 72, 72])
        XCTAssertEqual(StreamHealthAdvisor.evaluate(samples: dip, settings: settings, now: now), [])
        // Too few reports to judge yet.
        XCTAssertEqual(
            StreamHealthAdvisor.evaluate(samples: reports(fps: [50, 50]), settings: settings, now: now), [])

        let slow = reports(fps: [72, 72, 60, 58, 61, 59, 60, 62, 57])
        let issue = try XCTUnwrap(
            StreamHealthAdvisor.evaluate(samples: slow, settings: settings, now: now).first)
        XCTAssertEqual(issue.kind, .lowFrameRate)
        XCTAssertTrue(issue.detail.contains("60 fps against a 72 fps target"), issue.detail)
        XCTAssertTrue(issue.detail.contains("Balanced resolution"), issue.detail)

        settings.resolution = .balanced
        settings.fps = 90
        let at90 = reports(fps: [70, 71, 72, 70, 71])
        XCTAssertTrue(try XCTUnwrap(
            StreamHealthAdvisor.evaluate(samples: at90, settings: settings, now: now).first)
            .detail.contains("Try 72 fps"))
    }

    func testFlagsASilentHeadsetInsteadOfStaleFrameRates() {
        let settings = StreamLaunchSettings()
        let stale = reports(fps: [40, 40, 40, 40, 40], endingAt: now.addingTimeInterval(-10))
        let issues = StreamHealthAdvisor.evaluate(samples: stale, settings: settings, now: now)
        XCTAssertEqual(kinds(issues), [.headsetSilent])
        XCTAssertTrue(issues[0].detail.contains("10 s"))
        XCTAssertTrue(issues[0].detail.contains("USB cable"))
    }

    func testLatencyBudgetFollowsThePresetAndConnection() throws {
        var settings = StreamLaunchSettings()
        settings.latency = .balanced
        let latencies = [70.0, 95, 96, 97, 98, 99].map {
            StreamMetricSample(date: now, latencyMilliseconds: $0)
        }
        let wired = try XCTUnwrap(
            StreamHealthAdvisor.evaluate(samples: latencies, settings: settings, now: now).first)
        XCTAssertEqual(wired.kind, .highLatency)
        XCTAssertTrue(wired.detail.contains("Low latency preset"), wired.detail)

        settings.connection = .wifi
        XCTAssertTrue(try XCTUnwrap(
            StreamHealthAdvisor.evaluate(samples: latencies, settings: settings, now: now).first)
            .detail.contains("USB cable"))

        let typical = Array(repeating: StreamMetricSample(date: now, latencyMilliseconds: 55), count: 6)
        for preset in StreamLatencyPreset.allCases {
            settings.latency = preset
            XCTAssertEqual(
                StreamHealthAdvisor.evaluate(samples: typical, settings: settings, now: now), [],
                "\(preset) should accept the measured 47–58 ms pipeline")
        }
    }

    func testReportsMacPowerStateAfterStreamIssues() {
        let samples = reports(fps: [30, 30, 30, 30, 30])
        let issues = StreamHealthAdvisor.evaluate(
            samples: samples, settings: StreamLaunchSettings(),
            thermalState: .serious, lowPowerMode: true, now: now)
        XCTAssertEqual(kinds(issues), [.lowFrameRate, .thermalPressure, .lowPowerMode])
        XCTAssertEqual(
            kinds(StreamHealthAdvisor.evaluate(
                samples: [], settings: StreamLaunchSettings(), thermalState: .fair, now: now)),
            [])
    }

    func testMedianNeedsEnoughReports() {
        XCTAssertNil(StreamHealthAdvisor.median(of: [1, 2, 3, 4]))
        XCTAssertEqual(StreamHealthAdvisor.median(of: [5, 1, 3, 2, 4]), 3)
        XCTAssertEqual(StreamHealthAdvisor.median(of: [6, 1, 3, 2, 4, 5]), 3.5)
    }
}
