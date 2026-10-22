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

    func testPrefersUSBSerialWhenSameQuestAlsoAppearsOverWiFiADB() {
        let output = """
        List of devices attached
        192.168.1.42:5555      device product:eureka model:Quest_3 device:eureka transport_id:3
        QUEST3SERIAL01         device usb:1-1 product:eureka model:Quest_3 device:eureka transport_id:2

        """
        XCTAssertEqual(AlvrADBDeviceParser.authorizedUSBSerial(from: output),
                       "QUEST3SERIAL01")
        XCTAssertEqual(AlvrADBDeviceParser.authorizedNetworkSerials(from: output),
                       ["192.168.1.42:5555"])
    }

    func testUSBSelectionIsIndependentOfListingOrder() {
        let forward = """
        List of devices attached
        BBB device usb:1-2 transport_id:2
        AAA device usb:1-1 transport_id:3

        """
        let reversed = """
        List of devices attached
        AAA device usb:1-1 transport_id:3
        BBB device usb:1-2 transport_id:2

        """
        XCTAssertEqual(AlvrADBDeviceParser.authorizedUSBSerial(from: forward), "AAA")
        XCTAssertEqual(AlvrADBDeviceParser.authorizedUSBSerial(from: reversed), "AAA")
    }

    func testNetworkOnlyQuestIsNotAUSBSerialButIsReportedForTheErrorMessage() {
        let output = """
        List of devices attached
        emulator-5554 device product:sdk model:Emulator transport_id:1
        192.168.1.42:5555 device product:eureka model:Quest_3 transport_id:3
        adb-ABC123-xyz._adb-tls-connect._tcp device product:eureka transport_id:4
        192.168.1.9:5555 offline transport_id:5

        """
        XCTAssertNil(AlvrADBDeviceParser.authorizedUSBSerial(from: output))
        XCTAssertEqual(AlvrADBDeviceParser.authorizedNetworkSerials(from: output),
                       ["192.168.1.42:5555", "adb-ABC123-xyz._adb-tls-connect._tcp"])
    }

    func testNoDevicesYieldsNoSerials() {
        let output = "List of devices attached\n\n"
        XCTAssertNil(AlvrADBDeviceParser.authorizedUSBSerial(from: output))
        XCTAssertTrue(AlvrADBDeviceParser.authorizedNetworkSerials(from: output).isEmpty)
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

    func testFindsForwardsAdbDroppedForTheQuest() {
        let ports: [UInt16] = [9943, 9944]
        let list = """
            QUEST3SERIAL01 tcp:9943 tcp:9943
            QUEST3SERIAL01 tcp:9944 tcp:9944
            """
        XCTAssertEqual(AlvrADBDeviceParser.missingForwards(
            serial: "QUEST3SERIAL01", ports: ports, from: list), [])
        // Another device's forward does not count, nor does a remapped port.
        XCTAssertEqual(AlvrADBDeviceParser.missingForwards(
            serial: "QUEST3SERIAL01", ports: ports, from: """
                OTHER tcp:9943 tcp:9943
                QUEST3SERIAL01 tcp:9944 tcp:19944
                """), [9943, 9944])
        // adb removed both after the USB transport dropped.
        XCTAssertEqual(AlvrADBDeviceParser.missingForwards(
            serial: "QUEST3SERIAL01", ports: ports, from: ""), [9943, 9944])
    }
}
