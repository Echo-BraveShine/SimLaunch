import XCTest
@testable import SimLaunchCore

private actor InstallFixture {
    let platform: Platform
    var installed = false
    var fail = false
    var commands: [[String]] = []
    init(_ platform: Platform, fail: Bool = false) { self.platform = platform; self.fail = fail }
    func run(_ args: [String]) throws -> String {
        commands.append(args)
        if args.contains("install") || args.contains("install-multiple") {
            if fail { return "Failure [SIGNATURE_MISMATCH]" }
            installed = true
            return platform == .HarmonyOS ? "install bundle successfully." : "Success\n"
        }
        if platform == .iOS {
            return installed ? #"{"dev.test.installed":{"ApplicationType":"User","CFBundleVersion":"42","CFBundleShortVersionString":"1.0"}}"# : "{}"
        }
        if platform == .Android {
            if args.contains("get-current-user") { return "10" }
            if args.contains("dumpsys") { return "Package [dev.test.installed] (a):\n  versionCode=42\n  versionName=1.0\n  codePath=/data/app/test\n  lastUpdateTime=now" }
            if args.contains("packages") {
                return installed && !args.contains("-s", after: "packages") ? "package:dev.test.installed\n" : ""
            }
            return ""
        }
        if args.contains("-l") { return "[]" }
        if args.contains("-n") { return #"{"name":"dev.test.installed","versionCode":42,"versionName":"1.0","applicationInfo":{"isSystemApp":false,"removable":true}}"# }
        if args.contains("dump") { return "ID: 100:\n" + (installed ? "dev.test.installed\n" : "") }
        return ""
    }
    func history() -> [[String]] { commands }
}
private extension Array where Element == String {
    func contains(_ value: String, after marker: String) -> Bool {
        guard let index = firstIndex(of: marker) else { return false }
        return dropFirst(index + 1).contains(value)
    }
}

final class ApplicationInstallationTests: XCTestCase {
    private func package(_ platform: Platform, count: Int = 1) throws -> PreparedInstallation {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var app = InstalledApplication(id: "dev.test.installed", version: "1.0"); app.build = "42"
        return PreparedInstallation(application: app, files: (0..<count).map { root.appendingPathComponent("package-\($0)") }, fileNames: ["chosen file"], bytes: 100, platform: platform, directory: root)
    }
    private func service(_ platform: Platform, fixture: InstallFixture) -> ApplicationService {
        let device = Device(platform: platform, key: UUID().uuidString, name: "Fixture", state: .running)
        return ApplicationService(device: device, connector: { DeviceToolConnection(path: "/fixture", target: "exact-device") }, execute: { _, args, _, _ in try await fixture.run(args) })
    }
    func testThreePlatformsInstallAndVerifyExactDeviceAndUser() async throws {
        for platform in Platform.allCases {
            let fixture = InstallFixture(platform), package = try package(platform, count: platform == .iOS ? 1 : 2)
            let service = service(platform, fixture: fixture), before = try await service.list()
            let after = try await service.install(package, snapshot: before)
            XCTAssertTrue(after.applications.contains { $0.id == package.application.id })
            let history = await fixture.history(), command = try XCTUnwrap(history.first { $0.contains("install") || $0.contains("install-multiple") })
            XCTAssertTrue(command.contains("exact-device"))
            if platform == .Android { XCTAssertTrue(command.contains("install-multiple")); XCTAssertTrue(command.contains("--user")); XCTAssertTrue(command.contains("10")) }
            if platform == .HarmonyOS {
                XCTAssertTrue(command.contains("-u")); XCTAssertTrue(command.contains("100"))
                XCTAssertEqual(history.filter { $0.contains("send") }.count, 2)
                XCTAssertEqual(history.filter { $0.contains("rm") }.count, 1)
            }
            XCTAssertFalse(history.contains { $0.contains("uninstall") })
        }
    }
    func testFailureNeverUninstallsAndCleansHarmonyStaging() async throws {
        for platform in [Platform.Android, .HarmonyOS] {
            let fixture = InstallFixture(platform, fail: true), service = service(platform, fixture: fixture)
            let before = try await service.list()
            do { _ = try await service.install(package(platform), snapshot: before); XCTFail("Must reject CLI failure even with exit code zero") }
            catch { XCTAssertTrue(error.localizedDescription.contains("SIGNATURE_MISMATCH")) }
            let history = await fixture.history()
            XCTAssertFalse(history.contains { $0.contains("uninstall") })
            if platform == .HarmonyOS { XCTAssertTrue(history.contains { $0.contains("rm") }) }
        }
    }
    func testUserChangeBlocksInstallation() async throws {
        let fixture = InstallFixture(.Android), service = service(.Android, fixture: fixture)
        do { _ = try await service.install(package(.Android), snapshot: .init(applications: [], user: "99")); XCTFail("Must recheck device user") } catch {}
        let history = await fixture.history()
        XCTAssertFalse(history.contains { $0.contains("install") })
    }
    func testIOSChecksBinaryPlatformAndStagesSimulatorBundle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": "dev.test.simulator", "CFBundleExecutable": "Example", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        let executable = bundle.appendingPathComponent("Example")
        try FileManager.default.copyItem(at: ApplicationService.iconHelper("ios-simulator-icon"), to: executable)
        let prepared = try await ApplicationInstaller.prepare([bundle], platform: .iOS)
        XCTAssertEqual(prepared.application.id, "dev.test.simulator")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: executable)
        do { _ = try await ApplicationInstaller.prepare([bundle], platform: .iOS); XCTFail("A misleading plist cannot make a macOS executable a simulator app") } catch {}
    }
    private func hap(_ root: URL, name: String, bundle: String = "dev.test.hap", build: Int = 1, module: String = "entry", type: String = "entry") throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["app": ["bundleName": bundle, "versionName": "1.0", "versionCode": build], "module": ["name": module, "type": type]])
        try data.write(to: folder.appendingPathComponent("module.json"))
        let output = root.appendingPathComponent(name + ".hap"), zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = folder; zip.arguments = ["-q", output.path, "module.json"]
        try zip.run(); zip.waitUntilExit(); XCTAssertEqual(zip.terminationStatus, 0)
        return output
    }
    func testHAPValidationPrivateCopyAndMixedApplicationRejection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try hap(root, name: "entry"), feature = try hap(root, name: "feature", module: "feature", type: "feature")
        let ready = try await ApplicationInstaller.prepare([entry, feature], platform: .HarmonyOS)
        XCTAssertEqual(ready.application.id, "dev.test.hap"); XCTAssertEqual(ready.files.count, 2)
        XCTAssertNotEqual(ready.files.first, entry)
        try Data("changed after confirmation".utf8).write(to: entry)
        XCTAssertNotEqual(try Data(contentsOf: ready.files[0]), try Data(contentsOf: entry))
        let other = try hap(root, name: "other", bundle: "different.app", module: "other", type: "feature")
        do { _ = try await ApplicationInstaller.prepare([feature, other], platform: .HarmonyOS); XCTFail("Must reject mixed applications") } catch {}
        do { _ = try await ApplicationInstaller.prepare([feature], platform: .HarmonyOS); XCTFail("Must require an entry") } catch {}
        do { _ = try await ApplicationInstaller.prepare([other], platform: .Android); XCTFail("Must reject wrong platform") } catch {}
    }
}

final class ApplicationInstallationLiveTests: XCTestCase {
    func testDisposableMuMuApplicationInstallAndRemove() async throws {
        guard let path = ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_INSTALL_APK"] else { throw XCTSkip("Opt in with a disposable test APK and a running MuMu device") }
        let package = try await ApplicationInstaller.prepare([URL(fileURLWithPath: path)], platform: .Android)
        guard package.application.id.hasPrefix("dev.ekko.simlaunch.installtest") else { throw CLIError("Only disposable SimLaunch fixture packages are allowed") }
        let config = Configuration(), provider = MuMuProvider(Configuration())
        let devices = try await provider.list(), device = try XCTUnwrap(devices.first { $0.state == .running })
        let service = ApplicationService(device: device, configuration: config), before = try await service.list()
        XCTAssertFalse(before.applications.contains { $0.id == package.application.id })
        do {
            let after = try await service.install(package, snapshot: before)
            let app = try XCTUnwrap(after.applications.first { $0.id == package.application.id })
            let cleaned = try await service.uninstall(app, snapshot: after)
            XCTAssertFalse(cleaned.applications.contains { $0.id == package.application.id })
            print("Verified disposable install/uninstall on MuMu: " + package.application.id)
        } catch {
            if let current = try? await service.list(), let app = current.applications.first(where: { $0.id == package.application.id }) {
                _ = try? await service.uninstall(app, snapshot: current)
            }
            throw error
        }
    }
}
