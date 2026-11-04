import XCTest
@testable import SimLaunchCore

final class MuMuTests: XCTestCase {
    private func output(state: String = "stopped", directory: String = "/tmp/MuMu Device.mad", port: Int? = nil) throws -> String {
        var row: [String: Any] = ["index": 0, "name": "My Android", "state": state, "bundle_path": directory]
        if let port { row["adb_port"] = port }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["errcode": 0, "message": "", "return": ["count": 1, "results": [row]]]), as: UTF8.self)
    }
    private func executable(_ path: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
    private func fixture(_ root: URL, state: String = "stopped") throws -> (MuMuProvider, Device) {
        let text = try output(state: state, directory: root.appendingPathComponent("Guest.mad").path, port: 16384)
        try text.write(to: root.appendingPathComponent("snapshot"), atomically: true, encoding: .utf8)
        let tool = root.appendingPathComponent("MuMuPlayer.app/Contents/MacOS/mumutool")
        try executable(tool, """
        #!/bin/sh
        if [ "$1" = info ]; then
            /bin/cat '\(root.path)/snapshot'
        elif [ "$1" = --version ]; then
            echo 1.0.0
        else
            echo "$*" >> '\(root.path)/actions'
            if [ -f '\(root.path)/failure' ]; then
                echo '{"errcode":9,"message":"blocked"}'
            else
                echo '{"errcode":0,"message":"","return":{}}'
            fi
        fi
        """)
        let adb = tool.deletingLastPathComponent().appendingPathComponent("MuMuEmulator.app/Contents/MacOS/tools/adb")
        try executable(adb, """
        #!/bin/sh
        echo "$*" >> '\(root.path)/adb-start-actions'
        if [ -f '\(root.path)/adb-failure' ]; then exit 1; fi
        """)
        var config = Configuration(); config.mumuTool = tool.path
        return (MuMuProvider(config), try XCTUnwrap(MuMuProvider.parse(text).first))
    }
    func testADBFailurePreventsMuMuLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (provider, device) = try fixture(root)
        try Data().write(to: root.appendingPathComponent("adb-failure"))
        do { try await provider.start(device); XCTFail("Must fail when ADB cannot start") } catch {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("adb-start-actions")), "start-server\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("actions").path))
    }
    func testActualEnvelopeAndTransportIsolation() throws {
        let device = try XCTUnwrap(MuMuProvider.parse(output(state: "running", port: 16384)).first)
        XCTAssertEqual(device.id, "Android:MuMu:0")
        XCTAssertEqual(device.backend, .mumu)
        XCTAssertEqual(device.serial, "127.0.0.1:16384")
        XCTAssertEqual(device.state, .running)
        XCTAssertFalse(device.supportsColdBoot)
        XCTAssertNotEqual(device.id, Device(platform: .Android, key: "0", name: "AVD", state: .stopped).id)
        let adb = "List of devices attached\n127.0.0.1:16384\tdevice\n127.0.0.1:16416\toffline\nemulator-5554\tdevice\nUSB\tdevice\n"
        XCTAssertEqual(MuMuProvider.connectedTargets(adb), ["127.0.0.1:16384"])
        XCTAssertEqual(Parsers.adb(adb).map { $0.0 }, ["emulator-5554"], "MuMu must not create an extra AVD row")
        XCTAssertNil(try MuMuProvider.parse(output(port: 70000)).first?.serial)
        XCTAssertEqual(try MuMuProvider.parse(output(state: "new-future-state")).first?.state, .unknown)
    }
    func testFailureAndInvalidOutputNeverBecomeAnEmptyList() throws {
        for text in ["Error: URLSessionTask failed with error: Could not connect to the server.", "Error: invalidPort", "{}", "{\"errcode\":4,\"message\":\"denied\"}", "{\"errcode\":0,\"return\":{}}", "{\"errcode\":0,\"return\":{\"results\":[{\"index\":0}]}}"] {
            XCTAssertThrowsError(try MuMuProvider.parse(text))
        }
        XCTAssertTrue(try MuMuProvider.parse("{\"errcode\":0,\"return\":{\"results\":[]}}").isEmpty)
    }
    func testLifecycleUsesOnlySelectedIndexAndChecksZeroExitErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (provider, device) = try fixture(root)
        try await provider.start(device)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("adb-start-actions")), "start-server\n")
        try await provider.delete(device)
        let running = try output(state: "running", directory: device.directory!, port: 16384)
        try running.write(to: root.appendingPathComponent("snapshot"), atomically: true, encoding: .utf8)
        let live = try XCTUnwrap(MuMuProvider.parse(running).first)
        try await provider.stop(live)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("actions")), "open 0\ndelete 0\nclose 0\n")
        try Data().write(to: root.appendingPathComponent("failure"))
        do { try await provider.stop(live); XCTFail("Must reject errcode even when exit code is zero") }
        catch { XCTAssertTrue(error.localizedDescription.contains("blocked")) }
    }
    func testReusedIndexAndColdBootAreRejectedBeforeMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (provider, device) = try fixture(root)
        let replaced = try output(directory: root.appendingPathComponent("Another.mad").path)
        try replaced.write(to: root.appendingPathComponent("snapshot"), atomically: true, encoding: .utf8)
        for action in ["start", "delete", "cold"] {
            do {
                if action == "delete" { try await provider.delete(device) }
                else { try await provider.start(device, mode: action == "cold" ? .cold : .normal) }
                XCTFail("Must reject \(action)")
            } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("actions").path))
    }
    func testLogsAndInformationUseBundledADBAndExactPort() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (provider, device) = try fixture(root, state: "running")
        let tool = try await provider.path()
        let adb = URL(fileURLWithPath: tool).deletingLastPathComponent().appendingPathComponent("MuMuEmulator.app/Contents/MacOS/tools/adb")
        try executable(adb, """
        #!/bin/sh
        echo "$*" >> '\(root.path)/adb-actions'
        case "$1" in
          connect) echo connected ;;
          devices) printf 'List of devices attached\\n127.0.0.1:16416\\tdevice\\n127.0.0.1:16384\\tdevice\\n' ;;
          -s) printf '[ro.build.version.release]: [12]\\n[ro.build.version.sdk]: [32]\\n[ro.product.cpu.abi]: [arm64-v8a]\\n' ;;
        esac
        """)
        var config = Configuration(); config.mumuTool = tool
        let listed = try await provider.list()
        XCTAssertEqual(listed.first?.detail, "MuMu · Android 12 · API 32 · arm64")
        let command = try await LogConnection.command(device: device, configuration: config)
        XCTAssertEqual(command.path, adb.path)
        XCTAssertEqual(command.arguments, ["-s", "127.0.0.1:16384", "logcat", "-v", "threadtime"])
        let report = await DeviceInformationReader.read(device: device, configuration: config)
        XCTAssertTrue(report.report().contains("mumutool info"))
        XCTAssertTrue(report.sections.contains { $0.id == "Runtime properties" })
        let actions = try String(contentsOf: root.appendingPathComponent("adb-actions"))
        XCTAssertTrue(actions.contains("connect 127.0.0.1:16384"))
        XCTAssertFalse(actions.contains("-s 127.0.0.1:16416"))
    }
    private func offlineCatalog(_ root: URL) throws -> (Configuration, Device) {
        let (provider, device) = try fixture(root)
        let settings = URL(fileURLWithPath: device.directory!).appendingPathComponent("setting")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try #"{"vmName":"My Android","adbPort":16384,"vmMemoryOfMB":4096}"#.write(to: settings.appendingPathComponent("vm.json"), atomically: true, encoding: .utf8)
        let vms = root.appendingPathComponent("vms")
        try FileManager.default.createDirectory(at: vms, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: vms.appendingPathComponent("0").path, withDestinationPath: device.directory!)
        try "Error: invalidPort".write(to: root.appendingPathComponent("snapshot"), atomically: true, encoding: .utf8)
        return (provider.config, device)
    }
    func testClosedManagerListsDiskCatalogWithoutLaunchingOrUsingStoredPort() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (config, original) = try offlineCatalog(root)
        // Unregistered .mad backups must not become devices; broken links are ignored.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OldBackup.mad"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("vms/1").path, withDestinationPath: root.appendingPathComponent("missing.mad").path)
        let provider = MuMuProvider(config, catalogRoot: root, managerLauncher: { _ in XCTFail("Refresh must not launch MuMu") }, processList: { "" })
        let listed = try await provider.list()
        let offline = try XCTUnwrap(listed.first)
        XCTAssertEqual(offline.id, original.id)
        XCTAssertEqual(offline.state, .stopped)
        XCTAssertTrue(offline.isOfflineSnapshot)
        XCTAssertEqual(LogConnection.fingerprint(offline), LogConnection.fingerprint(original))
        XCTAssertNil(offline.serial, "A stored ADB port is not a live connection")
        try #"{"errcode":42005,"message":"RemoteWebServerError.invalidLaunch"}"#.write(to: root.appendingPathComponent("snapshot"), atomically: true, encoding: .utf8)
        let initializing = try await provider.list()
        XCTAssertTrue(initializing.first?.isOfflineSnapshot == true, "An info endpoint can be listening before the launcher is ready")
        try "Error: invalidPort".write(to: root.appendingPathComponent("snapshot"), atomically: true, encoding: .utf8)

        let uncertain = MuMuProvider(config, catalogRoot: root, processList: { "/Applications/MuMuPlayer.app/Contents/MacOS/MuMuEmulator.app/Contents/MacOS/MuMuEmulator" })
        let uncertainDevices = try await uncertain.list()
        XCTAssertEqual(uncertainDevices.first?.state, .unknown, "A surviving guest must never be labeled stopped")
        do { try await provider.delete(offline); XCTFail("Offline delete must not mutate local files") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.directory!))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("actions").path))
    }
    func testOfflineStartOpensSelectedDocumentAndConfirmsLiveIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (config, original) = try offlineCatalog(root)
        let running = try output(state: "running", directory: original.directory!, port: 16384)
        let provider = MuMuProvider(config, catalogRoot: root, managerLauncher: { selected in
            XCTAssertEqual(selected.directory, original.directory)
            try running.write(to: root.appendingPathComponent("snapshot"), atomically: true, encoding: .utf8)
        }, processList: { "" })
        let offlineDevices = try await provider.list()
        let offline = try XCTUnwrap(offlineDevices.first)
        let args = MuMuProvider.managerOpenArguments(tool: config.mumuTool!, device: offline)
        XCTAssertEqual(args, ["-a", root.appendingPathComponent("MuMuPlayer.app").path, original.directory!])
        try await provider.start(offline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("actions").path), "Do not open again if document launch already started it")
        try "Error: invalidPort".write(to: root.appendingPathComponent("snapshot"), atomically: true, encoding: .utf8)
        let replacement = try output(directory: root.appendingPathComponent("replacement.mad").path)
        let changed = MuMuProvider(config, catalogRoot: root, managerLauncher: { _ in
            try replacement.write(to: root.appendingPathComponent("snapshot"), atomically: true, encoding: .utf8)
        }, processList: { "" })
        do { try await changed.start(offline); XCTFail("Never open a reused index") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("actions").path))
    }
    func testFreshlyOpenedManagerRetriesTemporaryLauncherRejection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (config, original) = try offlineCatalog(root)
        let ready = try output(directory: original.directory!, port: 16384)
        try executable(URL(fileURLWithPath: config.mumuTool!), """
        #!/bin/sh
        if [ "$1" = info ]; then
            /bin/cat '\(root.path)/snapshot'
        elif [ ! -f '\(root.path)/tried' ]; then
            /usr/bin/touch '\(root.path)/tried'
            echo '{"errcode":42005,"message":"RemoteWebServerError.invalidLaunch"}'
        else
            echo "$*" > '\(root.path)/actions'
            echo '{"errcode":0,"return":{}}'
        fi
        """)
        let provider = MuMuProvider(config, catalogRoot: root, managerLauncher: { _ in
            try ready.write(to: root.appendingPathComponent("snapshot"), atomically: true, encoding: .utf8)
        }, processList: { "" })
        let devices = try await provider.list()
        try await provider.start(XCTUnwrap(devices.first))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("actions")), "open 0\n")
    }
    func testSettingsMigrationValidationAndAutomaticReset() throws {
        let legacy = #"{"developerDir":"","emulator":"","adb":"","harmony":"","avdHome":""}"#
        var config = try JSONDecoder().decode(Configuration.self, from: Data(legacy.utf8))
        XCTAssertNil(config.mumuTool)
        config.mumuTool = "/missing/mumutool"
        XCTAssertThrowsError(try config.validateManualPaths())
        XCTAssertFalse(config.usesAutomaticPaths(for: .Android))
        config.useAutomaticPaths(for: .Android)
        XCTAssertNil(config.mumuTool)
        XCTAssertTrue(config.usesAutomaticPaths(for: .Android))
    }
}

final class MuMuLiveTests: XCTestCase {
    func testInstalledMuMuReadOnlyIntegration() async throws {
        guard ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_MUMU"] == "1" else { throw XCTSkip("Opt in with SIMLAUNCH_TEST_MUMU=1") }
        let config = Configuration(), provider = MuMuProvider(Configuration())
        let devices = try await provider.list()
        XCTAssertFalse(devices.isEmpty)
        XCTAssertTrue(devices.allSatisfy { $0.backend == .mumu })
        if let live = devices.first(where: { $0.state == .running }) {
            let command = try await LogConnection.command(device: live, configuration: config)
            XCTAssertEqual(command.target, live.serial)
            let text = try await ProcessRunner().run(command.path, ["-s", command.target, "logcat", "-d", "-t", "20", "-v", "threadtime"], timeout: 15)
            XCTAssertTrue(text.components(separatedBy: .newlines).contains { DeviceLogParser.parse($0, platform: .Android, id: 1).pid != nil })
            let info = await DeviceInformationReader.read(device: live, configuration: config)
            XCTAssertTrue(info.sections.contains { $0.id == "Runtime properties" })
            print("MuMu live verified: count=\(devices.count), detail=\(live.detail), target=\(command.target), sections=\(info.sections.count)")
        }
    }
}

final class MuMuOfflineLiveTests: XCTestCase {
    func testClosedManagerCatalog() async throws {
        guard ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_MUMU_OFFLINE"] == "1" else { throw XCTSkip("Requires closed MuMu manager; opt in with SIMLAUNCH_TEST_MUMU_OFFLINE=1") }
        let provider = MuMuProvider(Configuration())
        do { _ = try MuMuProvider.response(await provider.rawList()); XCTFail("MuMu must be closed for this check") }
        catch is MuMuServiceUnavailable {}
        let devices = try await provider.list()
        XCTAssertFalse(devices.isEmpty)
        XCTAssertTrue(devices.allSatisfy { $0.isOfflineSnapshot && $0.state == .stopped && $0.serial == nil })
        print("MuMu closed-manager catalog verified: \(devices.map { $0.key + ":" + $0.name }.joined(separator: ", "))")
    }
    func testStartSelectedOfflineDeviceAndRestoreItToStopped() async throws {
        guard let index = ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_MUMU_START_INDEX"] else { throw XCTSkip("Opt in with a stopped MuMu device index") }
        let provider = MuMuProvider(Configuration())
        let baseline = try await provider.list()
        let selected = try XCTUnwrap(baseline.first { $0.key == index && $0.state == .stopped && $0.isOfflineSnapshot })
        do {
            print("MuMu test: starting selected offline device")
            try await provider.start(selected)
            print("MuMu test: start command accepted")
            let deadline = Date().addingTimeInterval(40)
            var live = try await provider.list()
            while live.first(where: { $0.id == selected.id })?.state != .running && Date() < deadline {
                try await Task.sleep(nanoseconds: 500_000_000)
                live = try await provider.list()
            }
            let started = try XCTUnwrap(live.first { $0.id == selected.id && $0.state == .running })
            XCTAssertTrue(live.filter { $0.id != selected.id }.allSatisfy { other in baseline.first { $0.id == other.id }?.state == other.state }, "Opening a document must not boot another device")
            print("MuMu test: stopping started device")
            try await provider.stop(started)
            print("MuMu test: stop command accepted")
            let stopDeadline = Date().addingTimeInterval(30)
            var restored = try await provider.list()
            while restored.first(where: { $0.id == selected.id })?.state != .stopped && Date() < stopDeadline {
                try await Task.sleep(nanoseconds: 500_000_000)
                restored = try await provider.list()
            }
            XCTAssertEqual(restored.first { $0.id == selected.id }?.state, .stopped)
            print("MuMu offline start/stop verified: index=\(index), name=\(selected.name)")
        } catch {
            if let fresh = try? await provider.list().first(where: { $0.id == selected.id && $0.state == .running }) { try? await provider.stop(fresh) }
            throw error
        }
    }
}
