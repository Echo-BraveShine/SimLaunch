import XCTest
@testable import SimLaunchCore

final class DeviceInformationTests: XCTestCase {
    func testIOSSelectionIncludesOnlyTheRequestedDeviceAndRuntime() throws {
        let json = #"{"devices":{"runtime-a":[{"udid":"other","name":"Other device","deviceTypeIdentifier":"type-other"}],"runtime-b":[{"udid":"selected","name":"Selected","deviceTypeIdentifier":"type-selected","isAvailable":false,"availabilityError":"Missing image"}]},"runtimes":[{"identifier":"runtime-a","version":"1"},{"identifier":"runtime-b","version":"2"}],"devicetypes":[{"identifier":"type-other"},{"identifier":"type-selected","modelIdentifier":"Model"}]}"#
        let result = try DeviceInformationReader.iosSelection(json, udid: "selected")
        XCTAssertEqual(result.device["name"] as? String, "Selected")
        XCTAssertEqual(result.device["availabilityError"] as? String, "Missing image")
        XCTAssertEqual(result.runtime["version"] as? String, "2")
        XCTAssertEqual(result.type["modelIdentifier"] as? String, "Model")
        XCTAssertThrowsError(try DeviceInformationReader.iosSelection(json, udid: "missing"))
        XCTAssertThrowsError(try DeviceInformationReader.iosSelection("not-json", udid: "selected"))
    }
    func testUnknownAndNestedFieldsAreRetainedAndPathsRecognized() {
        let fields = DeviceInformationReader.fields(["unknown": "future SDK field", "path": "/tmp/My Device", "object": ["x": 4], "empty": "", "null": NSNull()])
        XCTAssertEqual(fields.map(\.id), ["object", "path", "unknown"])
        XCTAssertEqual(fields.first { $0.id == "path" }?.isPath, true)
        XCTAssertTrue(fields.first { $0.id == "object" }!.value.contains("4"))
    }
    func testPropertiesPreserveEqualsAndIgnoreComments() {
        XCTAssertEqual(DeviceInformationReader.properties("# ignored=x\n; ignored=y\n hw.ramSize = 4096\nimage=a=b\nempty=\n"), ["hw.ramSize": "4096", "image": "a=b", "empty": ""])
    }
    func testStoppedDeviceConfigurationSurvivesMissingTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hw.ramSize=2048\nhw.cpu.arch=arm64\n".write(to: root.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        var device = Device(platform: .Android, key: "Offline", name: "Offline", state: .stopped)
        device.directory = root.path
        var config = Configuration(); config.emulator = "/not-found/emulator"; config.adb = "/not-found/adb"
        let result = await DeviceInformationReader.read(device: device, configuration: config)
        XCTAssertTrue(result.sections.contains { $0.id == "Device configuration" && $0.fields.contains { $0.id == "hw.ramSize" && $0.value == "2048" } })
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(result.raw.contains { $0.text.contains("2048") })
        XCTAssertFalse(result.report().isEmpty)
        let changed = await DeviceInformationReader.read(device: device, configuration: config, expectedIdentity: "previous-device")
        XCTAssertEqual(changed.warnings.count, 1)
        XCTAssertTrue(changed.raw.isEmpty, "Do not read a recreated device using the previous identity")
    }
    func testRunningAndroidQueriesOnlyTheFreshlyAssociatedSerial() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("avds/FakePhone.avd")
        let emulator = root.appendingPathComponent("sdk/emulator/emulator")
        let adb = root.appendingPathComponent("sdk/platform-tools/adb")
        for path in [directory, emulator.deletingLastPathComponent(), adb.deletingLastPathComponent()] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try "hw.cpu.arch=arm64\nhw.ramSize=2048\n".write(to: directory.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        let emulatorScript = "#!/bin/sh\ncase \"$*\" in -list-avds) echo FakePhone;; -version) echo 'Fake emulator version';; *) exit 9;; esac\n"
        let adbScript = """
        #!/bin/sh
        case "$*" in
        version) echo 'Fake ADB version';;
        devices) printf 'List of devices attached\\nemulator-5580 device\\n';;
        '-s emulator-5580 emu avd name') printf 'FakePhone\\nOK\\n';;
        '-s emulator-5580 shell getprop sys.boot_completed') echo 1;;
        '-s emulator-5580 shell getprop') printf '[ro.product.model]: [TestModel]\\n[ro.build.version.release]: [15]\\n[ro.build.version.sdk]: [35]\\n';;
        *) exit 9;;
        esac
        """
        for (path, script) in [(emulator, emulatorScript), (adb, adbScript)] {
            try script.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        var config = Configuration(); config.emulator = emulator.path; config.adb = adb.path; config.avdHome = directory.deletingLastPathComponent().path
        var device = Device(platform: .Android, key: "FakePhone", name: "FakePhone", state: .stopped, serial: "emulator-stale")
        device.directory = directory.path
        let result = await DeviceInformationReader.read(device: device, configuration: config)
        XCTAssertTrue(result.sections.contains { $0.id == "Runtime properties" && $0.fields.contains { $0.id == "ro.product.model" && $0.value == "TestModel" } })
        XCTAssertTrue(result.raw.contains { $0.id.contains("emulator-5580") })
        XCTAssertFalse(result.report().contains("emulator-stale"))
        XCTAssertTrue(result.warnings.isEmpty, result.warnings.joined(separator: "\n"))
    }
    func testReportIncludesSourcesWarningsAndRawData() {
        var info = DeviceInformation()
        info.sections = [.init("Basic information", source: "test-source", fields: [.init("Device name", "Selected")])]
        info.raw = [.init(id: "raw-source", text: "raw-data")]
        info.warnings = ["query failed"]
        let report = info.report()
        for value in ["test-source", "Selected", "query failed", "raw-source", "raw-data"] { XCTAssertTrue(report.contains(value)) }
    }
}
final class DeviceInformationLiveTests: XCTestCase {
    func testReadActualPlatformInformationWithoutStartingDevices() async throws {
        guard ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_DEVICE_INFO"] == "1" else { throw XCTSkip("Opt-in read-only device information checks") }
        let config = Configuration()
        let providers: [any DeviceProvider] = [IOSProvider(config), AndroidProvider(config, launches: LaunchManager()), HarmonyProvider(config, launches: LaunchManager())]
        for provider in providers {
            let devices = try await provider.list()
            let device = try XCTUnwrap(devices.first { $0.state == .running } ?? devices.first { $0.state != .unavailable } ?? devices.first)
            let result = await DeviceInformationReader.read(device: device, configuration: config, expectedIdentity: LogConnection.fingerprint(device))
            XCTAssertTrue(result.sections.contains { $0.id == "Device configuration" })
            XCTAssertTrue(result.sections.contains { $0.id == "Development environment" })
            XCTAssertFalse(result.raw.isEmpty)
            print("Device information verified: \(provider.platform), sections=\(result.sections.count), warnings=\(result.warnings.count)")
        }
    }
}
