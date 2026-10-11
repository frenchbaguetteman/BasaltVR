import XCTest
@testable import BasaltCore

final class AlvrWiredConnectionTests: XCTestCase {
    func testFindsADBInFallbackWhenFinderPathIsRestricted() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("basalt-adb-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let adb = directory.appendingPathComponent("adb")
        XCTAssertTrue(fileManager.createFile(
            atPath: adb.path, contents: Data("#!/bin/sh\n".utf8)))
        try fileManager.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: adb.path)

        XCTAssertEqual(
            AlvrADBExecutableLocator.find(
                environment: ["PATH": "/usr/bin:/bin"],
                fallbackDirectories: [directory.path],
                fileManager: fileManager),
            adb)
    }

    func testFindsAuthorizedPhysicalUSBDevice() {
        let output = """
        List of devices attached
        emulator-5554 device product:sdk model:Emulator transport_id:1
        TESTQUEST00001 device usb:0-1 product:eureka model:Quest_3 transport_id:2

        """
        XCTAssertEqual(AlvrADBDeviceParser.authorizedUSBSerial(from: output),
                       "TESTQUEST00001")
        XCTAssertFalse(AlvrADBDeviceParser.hasUnauthorizedDevice(in: output))
    }

    func testReportsUnauthorizedDeviceAndIgnoresNetworkADB() {
        let unauthorized = """
        List of devices attached
        TESTQUEST00001 unauthorized usb:0-1 transport_id:2

        """
        XCTAssertNil(AlvrADBDeviceParser.authorizedUSBSerial(from: unauthorized))
        XCTAssertTrue(AlvrADBDeviceParser.hasUnauthorizedDevice(in: unauthorized))

        let network = """
        List of devices attached
        192.168.1.20:5555 device product:eureka model:Quest_3 transport_id:3

        """
        XCTAssertNil(AlvrADBDeviceParser.authorizedUSBSerial(from: network))
    }

    func testSelectsInstalledALVRPackageByExactName() {
        XCTAssertEqual(AlvrADBDeviceParser.installedALVRPackage(from:
            "package:com.example.alvr.client\npackage:alvr.client.stable\n"),
            "alvr.client.stable")
        XCTAssertNil(AlvrADBDeviceParser.installedALVRPackage(from:
            "package:com.example.alvr.client\n"))
    }

    func testDetectsWhetherALVRActivityIsActuallyResumed() {
        XCTAssertTrue(AlvrADBDeviceParser.activityIsResumed(from: """
              mResumed=true mStopped=false mFinished=false
            """))
        XCTAssertFalse(AlvrADBDeviceParser.activityIsResumed(from: """
              isSleeping=true
              mResumed=false mStopped=true mFinished=false
              mLastPausedActivity: alvr.client/android.app.NativeActivity
            """))
    }
}
