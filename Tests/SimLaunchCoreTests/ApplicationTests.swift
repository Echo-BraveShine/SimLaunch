import XCTest
@testable import SimLaunchCore

private actor ApplicationFixture {
    let platform: Platform
    var installed = true
    var user = "0"
    var userAppIsSystem = false
    var failure: String?
    var keepAfterSuccess = false
    var commands: [[String]] = []
    var connections = 0
    var changeConnection = false
    let bundle = "dev.simlaunch.fixture"
    init(_ platform: Platform) { self.platform = platform; if platform == .HarmonyOS { user = "100" } }
    func connection() -> DeviceToolConnection {
        connections += 1
        return DeviceToolConnection(path: "/fixture/tool", target: changeConnection && connections > 1 ? "other-device" : "selected-device")
    }
    func configure(user: String? = nil, system: Bool? = nil, failure: String? = nil, keep: Bool = false, changeConnection: Bool = false) {
        if let user { self.user = user }; if let system { userAppIsSystem = system }; self.failure = failure; keepAfterSuccess = keep; self.changeConnection = changeConnection; connections = 0
    }
    func mutations() -> [[String]] { commands.filter { $0.contains("uninstall") } }
    func allCommands() -> [[String]] { commands }
    func run(_ args: [String]) throws -> String {
        commands.append(args)
        if args.contains("uninstall") {
            if let failure { return failure }
            if !keepAfterSuccess { installed = false }
            return platform == .iOS ? "" : platform == .Android ? "Success\n" : "uninstall bundle successfully.\n"
        }
        switch platform {
        case .iOS:
            var rows: [String: Any] = ["com.apple.safe": ["ApplicationType": "System", "CFBundleDisplayName": "System"]]
            if installed { rows[bundle] = ["ApplicationType": userAppIsSystem ? "System" : "User", "CFBundleDisplayName": "Fixture", "IsRemovable": true] }
            return String(decoding: try PropertyListSerialization.data(fromPropertyList: rows, format: .xml, options: 0), as: UTF8.self)
        case .Android:
            if args.contains("get-current-user") { return user + "\n" }
            if args.contains("packages") {
                if args.contains("-3") { return installed && !userAppIsSystem ? "package:\(bundle)\n" : "" }
                if args.dropFirst(2).contains("-s") { return "package:com.android.safe\n" + (installed && userAppIsSystem ? "package:\(bundle)\n" : "") }
                return "package:com.android.safe\n" + (installed ? "package:\(bundle)\n" : "")
            }
        case .HarmonyOS:
            if args.contains("-l") { return "[{\"bundleName\":\"\(bundle)\",\"label\":\"测试应用\"}]" }
            if let n = args.firstIndex(of: "-n") {
                let id = args[n + 1]
                return "\(id):\n{\"name\":\"\(id)\",\"versionName\":\"1.2\",\"applicationInfo\":{\"isSystemApp\":\(id != bundle || userAppIsSystem),\"removable\":true}}"
            }
            return "ID: \(user):\n\tcom.huawei.safe\n" + (installed ? "\t\(bundle)\n" : "")
        }
        throw CLIError("Unexpected fixture command: \(args)")
    }
}
final class ApplicationTests: XCTestCase {
    private func service(_ fixture: ApplicationFixture, platform: Platform) -> ApplicationService {
        ApplicationService(device: Device(platform: platform, key: "test", name: "Test", state: .running), connector: { await fixture.connection() }, execute: { _, args, _, _ in try await fixture.run(args) })
    }
    func testIOSOpenStepMetadataAndConservativeTypes() throws {
        let apps = try ApplicationParsers.ios(#"{ "com.test.user" = { ApplicationType = User; CFBundleDisplayName = "My App"; IsRemovable = 1; }; "com.test.system" = { ApplicationType = System; IsRemovable = 1; }; "com.test.unknown" = {}; }"#)
        XCTAssertTrue(apps.first { $0.id == "com.test.user" }!.canUninstall)
        XCTAssertFalse(apps.first { $0.id == "com.test.system" }!.canUninstall)
        XCTAssertFalse(apps.first { $0.id == "com.test.unknown" }!.canUninstall)
        XCTAssertThrowsError(try ApplicationParsers.ios("CoreSimulator disconnected"))
    }
    func testHarmonyActualNamesScopeAndSafetyFlags() throws {
        let snapshot = try ApplicationParsers.harmonyList("ID: 100:\n\tcom.test.user\n\tcom.test.system\n")
        XCTAssertEqual(snapshot.user, "100")
        XCTAssertEqual(try ApplicationParsers.harmonyLabels(#"[{"bundleName":"com.test.user","label":"测试应用"}]"#)["com.test.user"], "测试应用")
        let user = try ApplicationParsers.harmonyDetails(#"com.test.user: {"name":"com.test.user","versionName":"2.1","applicationInfo":{"isSystemApp":false,"removable":true}}"#, app: snapshot.applications[0])
        XCTAssertTrue(user.canUninstall)
        XCTAssertEqual(user.version, "2.1")
        XCTAssertThrowsError(try ApplicationParsers.harmonyDetails(#"{"name":"wrong","applicationInfo":{}}"#, app: user))
        XCTAssertThrowsError(try ApplicationParsers.harmonyList("error: device offline"))
        let multi = try ApplicationParsers.harmonyList("ID: 100:\ncom.a.one\nID: 101:\ncom.a.two\n")
        XCTAssertNil(multi.user, "Unknown user scope must not be guessed")
    }
    func testMaliciousIdentifiersAndFailureOutputAreRejected() throws {
        for id in ["-all", "com.test;reboot", "com.test app", "com.test\nother", "$(reboot)", ""] { XCTAssertFalse(ApplicationParsers.validIdentifier(id)) }
        XCTAssertThrowsError(try ApplicationParsers.androidPackages("Failure [offline]"))
        XCTAssertFalse(ApplicationParsers.uninstallSucceeded("Failure [DELETE_FAILED_INTERNAL_ERROR]", platform: .Android))
        XCTAssertFalse(ApplicationParsers.uninstallSucceeded("error: uninstall bundle successfully", platform: .HarmonyOS))
        XCTAssertFalse(ApplicationParsers.uninstallSucceeded("error", platform: .iOS))
    }
    func testThreePlatformsUninstallExactDeviceAndVerifyDisappearance() async throws {
        for platform in Platform.allCases {
            let fixture = ApplicationFixture(platform), service = service(fixture, platform: platform)
            let snapshot = try await service.list()
            var app = try XCTUnwrap(snapshot.applications.first { $0.id == "dev.simlaunch.fixture" })
            if platform == .HarmonyOS { app = try await service.metadata(app, snapshot: snapshot, connection: service.metadataConnection()) }
            let result = try await service.uninstall(app, snapshot: snapshot)
            XCTAssertFalse(result.applications.contains { $0.id == app.id })
            let mutations = await fixture.mutations()
            XCTAssertEqual(mutations.count, 1)
            XCTAssertTrue(mutations[0].contains("selected-device"))
            XCTAssertTrue(mutations[0].contains(app.id))
            XCTAssertFalse(mutations[0].contains("force-stop"), "Running apps are handled by the system uninstall flow")
            if platform == .Android { XCTAssertEqual(Array(mutations[0].suffix(3)), ["--user", "0", app.id]) }
            if platform == .HarmonyOS { XCTAssertEqual(Array(mutations[0].suffix(4)), ["-n", app.id, "-u", "100"]) }
        }
    }
    func testReclassifiedSystemAppAndChangedUserCannotBeUninstalled() async throws {
        for platform in Platform.allCases {
            let fixture = ApplicationFixture(platform), service = service(fixture, platform: platform)
            let snapshot = try await service.list()
            var app = try XCTUnwrap(snapshot.applications.first { $0.id == "dev.simlaunch.fixture" })
            app.kind = .user
            await fixture.configure(system: true)
            do { _ = try await service.uninstall(app, snapshot: snapshot); XCTFail("Fresh classification must reject system apps") } catch {}
            let mutations = await fixture.mutations(); XCTAssertTrue(mutations.isEmpty)
        }
        let fixture = ApplicationFixture(.Android), service = service(fixture, platform: .Android)
        let snapshot = try await service.list(), app = try XCTUnwrap(snapshot.applications.first { $0.canUninstall })
        await fixture.configure(user: "10")
        do { _ = try await service.uninstall(app, snapshot: snapshot); XCTFail("User changed") } catch {}
        let mutations = await fixture.mutations(); XCTAssertTrue(mutations.isEmpty)
    }
    func testChangedConnectionAndUnverifiedSuccessDoNotAppearSuccessful() async throws {
        let fixture = ApplicationFixture(.Android), service = service(fixture, platform: .Android)
        let snapshot = try await service.list(), app = try XCTUnwrap(snapshot.applications.first { $0.canUninstall })
        await fixture.configure(changeConnection: true)
        do { _ = try await service.uninstall(app, snapshot: snapshot); XCTFail("Connection changed") } catch {}
        var mutations = await fixture.mutations(); XCTAssertTrue(mutations.isEmpty)
        await fixture.configure(keep: true)
        do { _ = try await service.uninstall(app, snapshot: snapshot); XCTFail("Reported success is insufficient") } catch {}
        mutations = await fixture.mutations(); XCTAssertEqual(mutations.count, 1)
    }
    func testDetailsAreReadOnlyAndRejectChangedUserOrRemovedApplications() async throws {
        let fixture = ApplicationFixture(.Android), service = service(fixture, platform: .Android)
        let snapshot = try await service.list(), app = try XCTUnwrap(snapshot.applications.first { $0.canUninstall })
        await fixture.configure(user: "10")
        do { _ = try await service.details(app, snapshot: snapshot); XCTFail("Details must not cross users") } catch {}
        let mutations = await fixture.mutations(); XCTAssertTrue(mutations.isEmpty)
    }
    func testAPKBilingualLabelsAndVersionParsing() {
        let app = InstalledApplication(id: "com.test.app", kind: .user)
        let text = "package: name='com.test.app' versionCode='1' versionName='2.3'\napplication-label:'Test App'\napplication-icon-160:'res/icon.png'\napplication-icon-640:'../../unsafe.png'\n"
        let (enriched, icon) = ApplicationService.badging(text, app: app)
        XCTAssertEqual(enriched.name, "Test App"); XCTAssertEqual(enriched.version, "2.3"); XCTAssertEqual(icon, "res/icon.png")
        let literal = ApplicationService.badging("application: label='Literal App' icon='res/icon.png'", app: app)
        XCTAssertEqual(literal.0.name, "Literal App"); XCTAssertEqual(literal.1, "res/icon.png")
    }
    func testBinaryProcessOutputPreservesIconBytes() async throws {
        let data = try await ProcessRunner().runData("/usr/bin/printf", ["\\377\\000\\200"])
        XCTAssertEqual(data, Data([255, 0, 128]))
    }
}

final class ApplicationsLiveTests: XCTestCase {
    func testReadSelectedRunningDevices() async throws {
        guard ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_APPS"] == "1" else { throw XCTSkip("Opt in with SIMLAUNCH_TEST_APPS=1") }
        let config = Configuration()
        let providers: [(String, any DeviceProvider)] = [("iOS", IOSProvider(config)), ("Android", AndroidProvider(config, launches: LaunchManager())), ("MuMu", MuMuProvider(config)), ("HarmonyOS", HarmonyProvider(config, launches: LaunchManager()))]
        var checked = 0
        for (name, provider) in providers {
            if let chosen = ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_APPS_PLATFORM"], chosen != name { continue }
            guard let device = try await provider.list().first(where: { $0.state == .running }) else { continue }
            let service = ApplicationService(device: device, configuration: config)
            let snapshot = try await service.list()
            XCTAssertFalse(snapshot.applications.isEmpty)
            let connection = try await service.metadataConnection()
            var knownUser = 0
            for app in snapshot.applications.prefix(10) {
                let enriched = try await service.metadata(app, snapshot: snapshot, connection: connection)
                if enriched.kind == .user { knownUser += 1 }
            }
            print("Application list verified: platform=\(name), count=\(snapshot.applications.count), scope=\(snapshot.user ?? "n/a"), sampledUserApps=\(knownUser)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "At least one selected running simulator is required")
    }
    func testReadMuMuApplicationDetails() async throws {
        guard ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_APP_DETAILS"] == "1" else { throw XCTSkip("Requires a running MuMu simulator; read-only") }
        let provider = MuMuProvider(Configuration()), devices = try await provider.list()
        let device = try XCTUnwrap(devices.first { $0.state == .running })
        let service = ApplicationService(device: device, configuration: Configuration()), snapshot = try await service.list()
        for app in snapshot.applications.filter({ $0.kind == .user || $0.id == "com.android.settings" }).prefix(3) {
            let detail = try await service.details(app, snapshot: snapshot)
            XCTAssertEqual(detail.id, app.id); XCTAssertNotNil(detail.build)
            print("App detail verified: version=\(detail.version ?? "n/a"), build=\(detail.build ?? "n/a"), named=\(detail.name != nil), icon=\(detail.icon != nil), notes=\(detail.notes?.count ?? 0)")
        }
    }
    func testUninstallOwnedRunningAndroidFixture() async throws {
        guard ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_APPS_UNINSTALL_ANDROID"] == "1" else { throw XCTSkip("Requires an explicitly installed disposable Android fixture") }
        let config = Configuration(), provider = MuMuProvider(Configuration())
        let devices = try await provider.list()
        let device = try XCTUnwrap(devices.first { $0.key == "1" && $0.state == .running })
        let service = ApplicationService(device: device, configuration: config), snapshot = try await service.list()
        let app = try XCTUnwrap(snapshot.applications.first { $0.id == "dev.ekko.simlaunch.apps_test" && $0.canUninstall })
        let connection = try await service.metadataConnection()
        let enriched = try await service.metadata(app, snapshot: snapshot, connection: connection)
        XCTAssertEqual(enriched.displayName, "SimLaunch Test")
        let pid = try await ProcessRunner().run(connection.path, ["-s", connection.target, "shell", "pidof", app.id])
        XCTAssertFalse(pid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Fixture must be running before uninstall")
        let result = try await service.uninstall(enriched, snapshot: snapshot)
        XCTAssertFalse(result.applications.contains { $0.id == app.id })
    }
    func testUninstallOwnedRunningIOSFixture() async throws {
        guard ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_APPS_UNINSTALL_IOS"] == "1", let udid = ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_APPS_DEVICE"] else { throw XCTSkip("Requires an explicitly installed disposable test app") }
        let devices = try await IOSProvider(Configuration()).list()
        let device = try XCTUnwrap(devices.first { $0.key == udid && $0.state == .running })
        let service = ApplicationService(device: device, configuration: Configuration()), snapshot = try await service.list()
        let app = try XCTUnwrap(snapshot.applications.first { $0.id == "dev.ekko.simlaunch.apps-test" && $0.displayName == "SimLaunch Test" && $0.canUninstall })
        let result = try await service.uninstall(app, snapshot: snapshot)
        XCTAssertFalse(result.applications.contains { $0.id == app.id })
    }
}
