import XCTest
@testable import SimLaunchCore

final class CoreTests: XCTestCase {
    func testIOSAvailabilityAndState() throws {
        let devices = try Parsers.ios(#"{"devices":{"iOS 26":[{"udid":"1","name":"Phone","state":"Booted","isAvailable":true},{"udid":"2","name":"Old","state":"Shutdown","isAvailable":false}]}}"#)
        XCTAssertEqual(devices.map(\.state), [.running, .unavailable])
    }
    func testHarmonyActualSchema() throws {
        let devices = try Parsers.harmony(#"[{"name":"Mate 90 Pro","uuid":"abc","isRunning":"false","os.osVersion":"HarmonyOS 7.0.0"},{"name":"Phone","isRunning":true}]"#)
        XCTAssertEqual(devices[0].key, "Mate 90 Pro")
        XCTAssertEqual(devices.map(\.state), [.stopped, .running])
        XCTAssertThrowsError(try Parsers.harmony("unexpected table"))
        XCTAssertThrowsError(try Parsers.harmony("[{}]"))
    }
    func testADBExcludesPhysicalDevices() {
        let entries = Parsers.adb("List of devices attached\nphysical123 device\nemulator-5554 device\nemulator-5556 offline\n")
        XCTAssertEqual(entries.map { $0.0 }, ["emulator-5554", "emulator-5556"])
        XCTAssertEqual(Parsers.avdName("Pixel_9\nOK\n"), "Pixel_9")
        XCTAssertEqual(Parsers.avdName("Medium_Phone\r\nOK\r\n"), "Medium_Phone")
    }
    func testInvalidManualPathDoesNotSilentlyFallback() {
        XCTAssertThrowsError(try PathDiscovery.resolve("/missing/tool", candidates: ["/bin/echo"]))
    }
    func testRunnerArgumentsExitAndTimeout() async throws {
        let runner = ProcessRunner()
        let output = try await runner.run("/bin/echo", ["a b;$(whoami)"])
        XCTAssertEqual(output, "a b;$(whoami)\n")
        do { _ = try await runner.run("/usr/bin/false", []); XCTFail("Must fail") } catch {}
        do { _ = try await runner.run("/bin/sleep", ["5"], timeout: 0.1); XCTFail("Must time out") } catch {}
    }
    func testLargeOutputDoesNotDeadlock() async throws {
        let output = try await ProcessRunner().run("/usr/bin/awk", ["BEGIN { for(i=0;i<20000;i++) print \"abcdefghijklmnopqrstuvwxyz\" }"])
        XCTAssertGreaterThan(output.count, 500000)
    }
}

final class LocalSmokeTests: XCTestCase {
    func testInstalledProvidersReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["TRISIM_SMOKE"] == "1" else { throw XCTSkip("Set TRISIM_SMOKE=1 for local CLI integration") }
        let config = Configuration()
        let ios = try await IOSProvider(config).list()
        let harmony = try await HarmonyProvider(config, launches: LaunchManager()).list()
        print("Local devices: iOS=\(ios.count), HarmonyOS=\(harmony.count)")
        let android = try await AndroidProvider(config, launches: LaunchManager()).list()
        print("Local Android AVDs=\(android.count)")
        for device in android { print("Android metadata: \(device.name) | \(device.detail)") }
    }
}

final class IOSLaunchTests: XCTestCase {
    func testRealIOSLaunch() async throws {
        guard let udid = ProcessInfo.processInfo.environment["TRISIM_IOS_UDID"] else { throw XCTSkip("Explicit device required") }
        let provider = IOSProvider(Configuration())
        let devices = try await provider.list()
        let device = try XCTUnwrap(devices.first { $0.key == udid })
        try await provider.start(device)
        let updated = try await provider.list()
        XCTAssertEqual(updated.first { $0.key == udid }?.state, .running)
    }
}

final class SimulatorDiscoveryTests: XCTestCase {
    func testSimulatorDiscoveryAndExplicitOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Custom Xcode/Simulator.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Simulator")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertEqual(try PathDiscovery.resolveSimulator(nil, candidates: ["/missing/Simulator.app", app.path]), app.path)
        XCTAssertThrowsError(try PathDiscovery.resolveSimulator("/missing/Simulator.app", candidates: [app.path]))
        XCTAssertThrowsError(try PathDiscovery.resolveSimulator(nil, candidates: []))
    }
    func testExistingConfigurationRemainsDecodable() throws {
        let old = #"{"developerDir":"/custom/Xcode/Contents/Developer","emulator":"","adb":"","harmony":"","avdHome":""}"#
        let config = try JSONDecoder().decode(Configuration.self, from: Data(old.utf8))
        XCTAssertEqual(config.developerDir, "/custom/Xcode/Contents/Developer")
        XCTAssertNil(config.simulatorApp)
    }
}

final class DeviceHubTests: XCTestCase {
    func testXcode27HostAndDeepLink() throws {
        let candidates = PathDiscovery.simulatorCandidates(developerDir: "/Applications/Xcode.app/Contents/Developer")
        XCTAssertTrue(candidates.contains("/Applications/Xcode.app/Contents/Applications/DeviceHub.app"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("DeviceHub.app")
        let executable = app.appendingPathComponent("Contents/MacOS/DevicesTrampoline")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "DevicesTrampoline", "CFBundleIdentifier": "com.apple.dt.Devices"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(try PathDiscovery.resolveSimulator(nil, candidates: [app.path]), app.path)
        XCTAssertEqual(PathDiscovery.simulatorOpenArguments(path: app.path, udid: "test-id"), ["-a", app.path, "devices://device/open?id=test-id"])
        XCTAssertEqual(PathDiscovery.simulatorOpenArguments(path: "/old/Simulator.app", udid: "test-id"), ["-a", "/old/Simulator.app", "--args", "-CurrentDeviceUDID", "test-id"])
    }
}

final class AndroidRegistryTests: XCTestCase {
    func testStartupKeepsOriginalRowUntilBootCompletes() async {
        let registry = AndroidRegistry()
        let offline = await registry.devices(names: ["Pixel"], observations: [.init(serial: "emulator-5554", name: nil, connected: false, bootCompleted: false)])
        XCTAssertEqual(offline.count, 1)
        XCTAssertEqual(offline[0].key, "Pixel")
        let starting = await registry.devices(names: ["Pixel"], observations: [.init(serial: "emulator-5554", name: "Pixel", connected: true, bootCompleted: false)])
        XCTAssertEqual(starting.count, 1)
        XCTAssertEqual(starting[0].id, offline[0].id)
        XCTAssertEqual(starting[0].state, .starting)
        let ready = await registry.devices(names: ["Pixel"], observations: [.init(serial: "emulator-5554", name: "Pixel", connected: true, bootCompleted: true)])
        XCTAssertEqual(ready[0].id, offline[0].id)
        XCTAssertEqual(ready[0].state, .running)
        XCTAssertEqual(ready[0].serial, "emulator-5554")
        let transient = await registry.devices(names: ["Pixel"], observations: [.init(serial: "emulator-5554", name: nil, connected: false, bootCompleted: false)])
        XCTAssertEqual(transient.count, 1)
        XCTAssertEqual(transient[0].serial, "emulator-5554")
        let stopped = await registry.devices(names: ["Pixel"], observations: [])
        XCTAssertEqual(stopped[0].state, .stopped)
        let reused = await registry.devices(names: ["Pixel"], observations: [.init(serial: "emulator-5554", name: nil, connected: false, bootCompleted: false)])
        XCTAssertNil(reused[0].serial)
    }
    func testMultipleInstancesRemainDistinct() async {
        let devices = await AndroidRegistry().devices(names: ["Pixel"], observations: [
            .init(serial: "emulator-5554", name: "Pixel", connected: true, bootCompleted: true),
            .init(serial: "emulator-5556", name: "Pixel", connected: true, bootCompleted: true)])
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(Set(devices.map(\.id)).count, 2)
    }
}

final class ColdBootTests: XCTestCase {
    func testColdBootPreservesUserDataAndNamesWithSpaces() {
        let android = EmulatorLaunchArguments.android(name: "Pixel Fold", mode: .cold)
        XCTAssertEqual(android, ["-avd", "Pixel Fold", "-no-snapshot-load"])
        XCTAssertFalse(android.contains("-wipe-data"))
        let harmony = EmulatorLaunchArguments.harmony(name: "Mate 90 Pro", mode: .cold)
        XCTAssertEqual(harmony, ["-start", "Mate 90 Pro", "-bootMode", "coldboot"])
        XCTAssertFalse(harmony.contains("reset"))
        XCTAssertEqual(EmulatorLaunchArguments.android(name: "Pixel", mode: .normal), ["-avd", "Pixel"])
        XCTAssertEqual(EmulatorLaunchArguments.harmony(name: "Phone", mode: .normal), ["-start", "Phone"])
    }
}

final class DeviceManagementTests: XCTestCase {
    func testDeletionRejectsRunningAndUncertainDevices() {
        for state in [DeviceState.running, .starting, .unknown] {
            XCTAssertThrowsError(try DeviceDeletion.validate(Device(platform: .Android, key: "Pixel", name: "Pixel", state: state)))
        }
        XCTAssertNoThrow(try DeviceDeletion.validate(Device(platform: .iOS, key: "id", name: "Old", state: .unavailable)))
    }
    func testDirectoryUsesCustomAVDINIAndHarmonyInstancePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "path=/custom location/Pixel.avd\r\n".write(to: root.appendingPathComponent("Pixel.ini"), atomically: true, encoding: .utf8)
        var config = Configuration(); config.avdHome = root.path
        XCTAssertEqual(DeviceDirectories.android(name: "Pixel", config: config), "/custom location/Pixel.avd")
        XCTAssertNil(DeviceDirectories.android(name: "../Pixel", config: config))
        let harmony = try Parsers.harmony(#"[{"name":"Mate 90 Pro","isRunning":"false","instancePath":"/custom/Mate 90 Pro"}]"#)
        XCTAssertEqual(harmony[0].directory, "/custom/Mate 90 Pro")
    }
}

final class LocalizationTests: XCTestCase {
    func testEnglishAndChineseUIStringsAreBundled() {
        XCTAssertEqual(L10n.text("常用", language: "en"), "Recent")
        XCTAssertEqual(L10n.text("常用", language: "zh-Hans"), "常用")
        XCTAssertEqual(L10n.text("冷启动", language: "en"), "Cold boot")
        XCTAssertEqual(L10n.text("删除当前设备", language: "en"), "Delete device")
        XCTAssertEqual(L10n.text(DeviceState.running.rawValue, language: "en"), "Running")
        XCTAssertEqual(L10n.text("保存并刷新", language: "en"), "Save and refresh")
    }
    func testDeletionMessageRetainsDeviceIdentityAcrossLanguages() {
        let key = "Permanently delete %@ device “%@” and all its apps and data? This cannot be undone."
        for language in ["en", "zh-Hans"] {
            let result = String(format: L10n.text(key, language: language), "HarmonyOS", "Mate 90 Pro")
            XCTAssertTrue(result.contains("HarmonyOS"))
            XCTAssertTrue(result.contains("Mate 90 Pro"))
            XCTAssertFalse(result.contains("%@"))
        }
    }
}

final class PreferencesMigrationTests: XCTestCase {
    func testMigrationPreservesExistingSettingsAndRunsOnce() throws {
        let suite = "SimLaunch-MigrationTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en", forKey: "appLanguage")
        let old: [String: Any] = ["appLanguage": "zh-Hans", "recentDeviceIDs": ["iOS:device"], "configuration": Data([1, 2, 3]), "unrelated": "ignored"]
        AppPreferences.migrateIfNeeded(in: defaults, legacyDomain: old)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
        XCTAssertEqual(defaults.stringArray(forKey: "recentDeviceIDs"), ["iOS:device"])
        XCTAssertEqual(defaults.data(forKey: "configuration"), Data([1, 2, 3]))
        XCTAssertNil(defaults.object(forKey: "unrelated"))
        defaults.removeObject(forKey: "recentDeviceIDs")
        AppPreferences.migrateIfNeeded(in: defaults, legacyDomain: old)
        XCTAssertNil(defaults.object(forKey: "recentDeviceIDs"))
        XCTAssertEqual(AppPreferences.bundleIdentifier, "dev.ekko.simlaunch")
    }
}
