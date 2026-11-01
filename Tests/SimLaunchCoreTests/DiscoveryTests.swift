import XCTest
@testable import SimLaunchCore

private final class DiscoveryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SimLaunch discovery " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func directory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func executable(_ relative: String, body: String = "exit 0\n") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func simulator(_ relative: String, executable: String = "Simulator") throws -> URL {
        let app = root.appendingPathComponent(relative)
        _ = try self.executable(relative + "/Contents/MacOS/" + executable)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": executable], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
}

final class PathConfigurationTests: XCTestCase {
    func testCLIResolutionRejectsDirectoriesAndSkipsNonExecutableFiles() throws {
        let fixture = try DiscoveryFixture()
        let directory = try fixture.directory("not an executable")
        let text = fixture.root.appendingPathComponent("readme")
        try "not executable".write(to: text, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: text.path)
        let executable = try fixture.executable("SDK/emulator/emulator")

        XCTAssertThrowsError(try PathDiscovery.resolve(directory.path, candidates: [executable.path]))
        XCTAssertThrowsError(try PathDiscovery.resolve(text.path, candidates: [executable.path]))
        XCTAssertEqual(try PathDiscovery.resolve("", candidates: [directory.path, text.path, executable.path]), executable.path)
    }

    func testSymlinkedEmulatorFindsADBInItsActualSDK() throws {
        let fixture = try DiscoveryFixture()
        let emulator = try fixture.executable("custom SDK/emulator/emulator")
        let adb = try fixture.executable("custom SDK/platform-tools/adb")
        let aliases = try fixture.directory("aliases")
        let alias = aliases.appendingPathComponent("emulator")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: emulator)
        var config = Configuration()
        config.emulator = alias.path
        let provider = AndroidProvider(config, launches: LaunchManager())

        XCTAssertEqual(try provider.emulator(), alias.path)
        XCTAssertEqual(try provider.adb(), adb.path)
    }

    func testExplicitADBOverridesSiblingAndInvalidManualADBDoesNotFallback() throws {
        let fixture = try DiscoveryFixture()
        let emulator = try fixture.executable("SDK/emulator/emulator")
        _ = try fixture.executable("SDK/platform-tools/adb")
        let otherADB = try fixture.executable("chosen tools/adb")
        var config = Configuration()
        config.emulator = emulator.path
        config.adb = otherADB.path
        XCTAssertEqual(try AndroidProvider(config, launches: LaunchManager()).adb(), otherADB.path)

        config.adb = fixture.root.appendingPathComponent("missing adb").path
        XCTAssertThrowsError(try AndroidProvider(config, launches: LaunchManager()).adb())
    }

    func testManualAndroidPathsWithSpacesAndCustomAVDHomeReachTheProvider() async throws {
        let fixture = try DiscoveryFixture()
        let avdHome = try fixture.directory("custom AVD home")
        let avd = try fixture.directory("custom AVD home/Fixture_Phone.avd")
        let expected = avdHome.path.replacingOccurrences(of: "'", with: "'\\''")
        let emulator = try fixture.executable("SDK tools/emulator/emulator", body: """
        [ "$1" = '-list-avds' ] || exit 64
        [ "$ANDROID_AVD_HOME" = '\(expected)' ] || exit 65
        printf 'Fixture_Phone\\n'
        """)
        let adb = try fixture.executable("SDK tools/platform-tools/adb", body: """
        [ "$1" = 'devices' ] || exit 64
        printf 'List of devices attached\\n'
        """)
        var config = Configuration()
        config.emulator = emulator.path
        config.adb = adb.path
        config.avdHome = avdHome.path

        let devices = try await AndroidProvider(config, launches: LaunchManager()).list()
        XCTAssertEqual(devices.map(\.id), ["Android:Fixture_Phone"])
        XCTAssertEqual(devices.first?.directory, avd.path)
        XCTAssertEqual(devices.first?.state, .stopped)
    }

    func testManualHarmonyCLIWithSpacesIsUsedForListing() async throws {
        let fixture = try DiscoveryFixture()
        let emulator = try fixture.executable("DevEco Custom.app/Contents/tools/emulator/Emulator", body: """
        [ "$1" = '-list' ] && [ "$2" = '-details' ] || exit 64
        printf '%s\\n' '[{"name":"Fixture Phone","isRunning":"false","os.osVersion":"HarmonyOS 5.0"}]'
        """)
        var config = Configuration()
        config.harmony = emulator.path
        let provider = HarmonyProvider(config, launches: LaunchManager())
        let resolved = try await provider.path()
        XCTAssertEqual(resolved, emulator.path)
        let devices = try await provider.list()
        XCTAssertEqual(devices.map(\.id), ["HarmonyOS:Fixture Phone"])
        XCTAssertEqual(devices.first?.detail, "HarmonyOS 5.0")
    }

    func testSimulatorResolutionRejectsExecutableDirectoryAndUnsafeMetadata() throws {
        let fixture = try DiscoveryFixture()
        let valid = try fixture.simulator("Xcode Custom.app/Contents/Developer/Applications/Simulator.app")
        let invalid = try fixture.directory("Broken.app/Contents/MacOS/Simulator")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertThrowsError(try PathDiscovery.resolveSimulator(invalid.path, candidates: [valid.path]))

        let bad = try fixture.directory("Unsafe.app/Contents/MacOS")
            .deletingLastPathComponent().deletingLastPathComponent()
        let metadata = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "../outside"], format: .xml, options: 0)
        try metadata.write(to: bad.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try PathDiscovery.resolveSimulator(bad.path, candidates: [valid.path]))
        XCTAssertEqual(try PathDiscovery.resolveSimulator(nil, candidates: [invalid.path, bad.path, valid.path]), valid.path)
    }

    func testEmptyAndTildePathsProduceOnlyTheExpectedChildEnvironment() {
        var config = Configuration()
        XCTAssertTrue(config.iosEnvironment.isEmpty)
        XCTAssertTrue(config.androidEnvironment.isEmpty)
        config.developerDir = "~/Custom Xcode.app/Contents/Developer"
        config.avdHome = "~/Custom Devices"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(config.iosEnvironment, ["DEVELOPER_DIR": home + "/Custom Xcode.app/Contents/Developer"])
        XCTAssertEqual(config.androidEnvironment, ["ANDROID_AVD_HOME": home + "/Custom Devices"])
    }

    func testValidationAllowsAutomaticConfigurationAndValidManualTools() throws {
        XCTAssertNoThrow(try Configuration().validateManualPaths())
        let fixture = try DiscoveryFixture()
        let xcode = try fixture.executable("Custom Xcode.app/Contents/Developer/usr/bin/simctl")
        let developer = xcode.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var config = Configuration()
        config.developerDir = developer.path
        config.simulatorApp = try fixture.simulator("Custom Xcode.app/Contents/Applications/DeviceHub.app", executable: "DevicesTrampoline").path
        config.emulator = try fixture.executable("custom SDK/emulator/emulator").path
        config.adb = try fixture.executable("custom SDK/platform-tools/adb").path
        config.harmony = try fixture.executable("DevEco Custom.app/Contents/tools/emulator/Emulator").path
        config.avdHome = try fixture.directory("custom AVD home").path
        XCTAssertNoThrow(try config.validateManualPaths())

        config.developerDir = developer.deletingLastPathComponent().deletingLastPathComponent().path
        XCTAssertNoThrow(try config.validateManualPaths(), "The enclosing Xcode.app is also accepted by xcrun")
    }

    func testValidationRejectsInvalidManualFieldsWithoutRequiringOtherPlatforms() throws {
        let fixture = try DiscoveryFixture()
        let directory = try fixture.directory("ordinary folder")
        let file = fixture.root.appendingPathComponent("ordinary file")
        try "readme".write(to: file, atomically: true, encoding: .utf8)
        let missing = fixture.root.appendingPathComponent("missing tool").path
        for invalid in [directory.path, file.path, missing] {
            var config = Configuration()
            config.emulator = invalid
            XCTAssertThrowsError(try config.validateManualPaths())
            config = Configuration(); config.adb = invalid
            XCTAssertThrowsError(try config.validateManualPaths())
            config = Configuration(); config.harmony = invalid
            XCTAssertThrowsError(try config.validateManualPaths())
        }
        for invalid in [file.path, missing] {
            var config = Configuration(); config.avdHome = invalid
            XCTAssertThrowsError(try config.validateManualPaths())
        }
        var config = Configuration(); config.developerDir = directory.path
        XCTAssertThrowsError(try config.validateManualPaths())
        config = Configuration(); config.simulatorApp = directory.path
        XCTAssertThrowsError(try config.validateManualPaths())

        // An Android-only configuration can be saved without Xcode or DevEco paths.
        config = Configuration()
        config.emulator = try fixture.executable("only Android/emulator").path
        XCTAssertNoThrow(try config.validateManualPaths())
    }

    func testAutomaticResetOnlyChangesTheSelectedPlatform() {
        var config = Configuration()
        config.developerDir = "/chosen Xcode/Contents/Developer"
        config.simulatorApp = "/chosen Xcode/Simulator.app"
        config.emulator = "/chosen SDK/emulator/emulator"
        config.adb = "/chosen SDK/platform-tools/adb"
        config.avdHome = "/chosen AVD home"
        config.harmony = "/chosen DevEco/Emulator"
        XCTAssertFalse(config.usesAutomaticPaths(for: .iOS))
        XCTAssertFalse(config.usesAutomaticPaths(for: .Android))
        XCTAssertFalse(config.usesAutomaticPaths(for: .HarmonyOS))

        config.useAutomaticPaths(for: .Android)
        XCTAssertTrue(config.usesAutomaticPaths(for: .Android))
        XCTAssertEqual(config.developerDir, "/chosen Xcode/Contents/Developer")
        XCTAssertEqual(config.simulatorApp, "/chosen Xcode/Simulator.app")
        XCTAssertEqual(config.harmony, "/chosen DevEco/Emulator")
        config.useAutomaticPaths(for: .iOS)
        XCTAssertTrue(config.usesAutomaticPaths(for: .iOS))
        XCTAssertEqual(config.harmony, "/chosen DevEco/Emulator")
        config.useAutomaticPaths(for: .HarmonyOS)
        XCTAssertEqual(config, Configuration())
    }
}

final class LocalDiscoverySmokeTests: XCTestCase {
    func testInstalledAutomaticAndExplicitConfigurationsReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["TRISIM_SMOKE"] == "1" else {
            throw XCTSkip("Set TRISIM_SMOKE=1 for read-only installed-tool discovery checks")
        }
        let automatic = Configuration()
        let ios = IOSProvider(automatic)
        let iosDevices = try await ios.list()
        let simulator = try await ios.simulatorPath()
        let simctl = try await ProcessRunner().run("/usr/bin/xcrun", ["--find", "simctl"])
        let developer = URL(fileURLWithPath: simctl.trimmingCharacters(in: .whitespacesAndNewlines))
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        var manual = Configuration()
        manual.developerDir = developer
        manual.simulatorApp = simulator
        let manualIOS = IOSProvider(manual)
        let manualSimulator = try await manualIOS.simulatorPath()
        XCTAssertEqual(manualSimulator, simulator)
        let manualIOSDevices = try await manualIOS.list()
        XCTAssertEqual(Set(manualIOSDevices.map(\.id)), Set(iosDevices.map(\.id)))
        print("iOS discovery: \(developer) | \(simulator) | \(iosDevices.count) devices; explicit paths match")

        let android = AndroidProvider(automatic, launches: LaunchManager())
        let emulator = try android.emulator()
        let adb = try android.adb()
        let androidDevices = try await android.list()
        manual = Configuration()
        manual.emulator = emulator
        manual.adb = adb
        let environment = ProcessInfo.processInfo.environment
        let userHome = environment["ANDROID_USER_HOME"] ?? environment["ANDROID_EMULATOR_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android").path
        let avdHome = PathDiscovery.expand(environment["ANDROID_AVD_HOME"] ?? userHome + "/avd")
        if FileManager.default.fileExists(atPath: avdHome) { manual.avdHome = avdHome }
        let manualAndroid = AndroidProvider(manual, launches: LaunchManager())
        XCTAssertEqual(try manualAndroid.emulator(), emulator)
        XCTAssertEqual(try manualAndroid.adb(), adb)
        let manualAndroidDevices = try await manualAndroid.list()
        XCTAssertEqual(Set(manualAndroidDevices.map(\.id)), Set(androidDevices.map(\.id)))
        print("Android discovery: \(emulator) | \(adb) | AVD home \(manual.avdHome.isEmpty ? "automatic" : manual.avdHome) | \(androidDevices.count) devices; explicit paths match")

        let harmony = HarmonyProvider(automatic, launches: LaunchManager())
        let harmonyPath = try await harmony.path()
        let harmonyDevices = try await harmony.list()
        manual = Configuration()
        manual.harmony = harmonyPath
        let manualHarmony = HarmonyProvider(manual, launches: LaunchManager())
        let manualHarmonyPath = try await manualHarmony.path()
        XCTAssertEqual(manualHarmonyPath, harmonyPath)
        let manualHarmonyDevices = try await manualHarmony.list()
        XCTAssertEqual(Set(manualHarmonyDevices.map(\.id)), Set(harmonyDevices.map(\.id)))
        print("HarmonyOS discovery: \(harmonyPath) | \(harmonyDevices.count) devices; explicit path matches")
    }
}
