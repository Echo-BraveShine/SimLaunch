import Foundation

public enum Parsers {
    public static func iosRuntime(_ identifier: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard identifier.hasPrefix(prefix) else { return identifier }
        let components = identifier.dropFirst(prefix.count).split(separator: "-")
        guard let platform = components.first else { return "iOS" }
        return String(platform) + (components.count > 1 ? " " + components.dropFirst().joined(separator: ".") : "")
    }
    public static func ios(_ text: String) throws -> [Device] {
        struct Root: Decodable { let devices: [String: [Entry]] }
        struct Entry: Decodable { let udid: String; let name: String; let state: String; let isAvailable: Bool?; let availabilityError: String?; let dataPath: String? }
        let root = try JSONDecoder().decode(Root.self, from: Data(text.utf8))
        return root.devices.sorted { $0.key < $1.key }.flatMap { runtime, entries in entries.map { entry in
            let version = iosRuntime(runtime)
            let detail = [version, entry.availabilityError].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            var device = Device(platform: .iOS, key: entry.udid, name: entry.name, state: entry.isAvailable == false ? .unavailable : (entry.state == "Booted" ? .running : (entry.state == "Shutdown" ? .stopped : .starting)), detail: detail)
            device.directory = entry.dataPath ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/CoreSimulator/Devices/" + entry.udid).path
            return device
        } }
    }
    public static func adb(_ text: String) -> [(String, String)] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0].hasPrefix("emulator-") else { return nil }
            return (String(fields[0]), String(fields[1]))
        }
    }
    public static func avdName(_ text: String) -> String? {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty && $0 != "OK" && !$0.hasPrefix("*") && !$0.hasPrefix("KO") }
    }
    public static func harmony(_ text: String) throws -> [Device] {
        // DevEco 26 emits a JSON array, isRunning is a string (some versions use Bool).
        guard let begin = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), begin <= end,
              let rows = try JSONSerialization.jsonObject(with: Data(text[begin...end].utf8)) as? [[String: Any]] else {
            throw CLIError(L10n.format("Cannot parse HarmonyOS -list -details output. Check the CLI version. %@", String(text.prefix(500))))
        }
        return try rows.map { row in
            guard let name = row["name"] as? String, !name.isEmpty else { throw CLIError(L10n.text("HarmonyOS 设备缺少 name 字段")) }
            let raw = String(describing: row["isRunning"] ?? "unknown").lowercased()
            let state: DeviceState = ["true", "1"].contains(raw) ? .running : (["false", "0"].contains(raw) ? .stopped : .unknown)
            var device = Device(platform: .HarmonyOS, key: name, name: name, state: state, detail: row["os.osVersion"] as? String ?? "HarmonyOS")
            device.instanceID = row["uuid"] as? String
            device.directory = row["instancePath"] as? String
            return device
        }
    }
}

public struct IOSProvider: DeviceProvider {
    public let platform = Platform.iOS
    let config: Configuration
    let runner = ProcessRunner()
    public init(_ config: Configuration) { self.config = config }
    public func list() async throws -> [Device] { try Parsers.ios(await runner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], environment: config.iosEnvironment)) }
    public func simulatorPath() async throws -> String {
        let tool = try await runner.run("/usr/bin/xcrun", ["--find", "simctl"], environment: config.iosEnvironment)
        let developer = URL(fileURLWithPath: tool.trimmingCharacters(in: .whitespacesAndNewlines)).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        var candidates = PathDiscovery.simulatorCandidates(developerDir: developer)
        if (config.simulatorApp ?? "").isEmpty,
           let discovered = try? await runner.run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == 'com.apple.iphonesimulator' || kMDItemCFBundleIdentifier == 'com.apple.dt.Devices'"], timeout: 5) {
            candidates += discovered.split(separator: "\n").map(String.init)
        }
        return try PathDiscovery.resolveSimulator(config.simulatorApp, candidates: candidates)
    }
    public func reveal(_ d: Device) async throws {
        let path = try await simulatorPath()
        _ = try await runner.run("/usr/bin/open", PathDiscovery.simulatorOpenArguments(path: path, udid: d.key))
    }
    public func start(_ d: Device, mode: BootMode) async throws {
        // Validate the GUI before booting, so a missing app never leaves a headless device.
        let path = try await simulatorPath()
        if d.state != .running {
            _ = try await runner.run("/usr/bin/xcrun", ["simctl", "boot", d.key], environment: config.iosEnvironment, timeout: 120)
        }
        _ = try await runner.run("/usr/bin/open", PathDiscovery.simulatorOpenArguments(path: path, udid: d.key))
    }
    public func delete(_ d: Device) async throws {
        try DeviceDeletion.validate(d)
        _ = try await runner.run("/usr/bin/xcrun", ["simctl", "delete", d.key], environment: config.iosEnvironment, timeout: 60)
    }
    public func stop(_ d: Device) async throws { _ = try await runner.run("/usr/bin/xcrun", ["simctl", "shutdown", d.key], environment: config.iosEnvironment) }
}

public struct AndroidProvider: DeviceProvider {
    public let platform = Platform.Android
    let config: Configuration
    let launches: LaunchManager
    let runner = ProcessRunner()
    let registry: AndroidRegistry
    let metadata: AndroidMetadataCache
    public init(_ config: Configuration, launches: LaunchManager, registry: AndroidRegistry = AndroidRegistry(), metadata: AndroidMetadataCache = AndroidMetadataCache()) { self.config = config; self.launches = launches; self.registry = registry; self.metadata = metadata }
    func emulator() throws -> String { try PathDiscovery.resolve(config.emulator, candidates: PathDiscovery.sdkRoots.map { $0 + "/emulator/emulator" } + PathDiscovery.pathCandidates("emulator")) }
    func adb() throws -> String {
        let sibling = (try? emulator()).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("platform-tools/adb").path }
        return try PathDiscovery.resolve(config.adb, candidates: [sibling].compactMap { $0 } + PathDiscovery.sdkRoots.map { $0 + "/platform-tools/adb" } + PathDiscovery.pathCandidates("adb"))
    }
    public func list() async throws -> [Device] {
        let emulatorPath = try emulator()
        let names = try await runner.run(emulatorPath, ["-list-avds"], environment: config.androidEnvironment).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let adbPath = try adb()
        let entries = try Parsers.adb(await runner.run(adbPath, ["devices"]))
        var observations: [AndroidObservation] = []
        for (serial, status) in entries {
            var name: String?
            var bootCompleted = false
            if status == "device" {
                if let output = try? await runner.run(adbPath, ["-s", serial, "emu", "avd", "name"], timeout: 5) {
                    name = Parsers.avdName(output)
                }
                if let output = try? await runner.run(adbPath, ["-s", serial, "shell", "getprop", "sys.boot_completed"], timeout: 5) {
                    bootCompleted = output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                }
            }
            observations.append(AndroidObservation(serial: serial, name: name, connected: status == "device", bootCompleted: bootCompleted))
        }
        var devices = await registry.devices(names: names, observations: observations)
        let sdkRoot = URL(fileURLWithPath: emulatorPath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().path
        await metadata.retainRuntimeKeys(Set(entries.map { adbPath + ":" + $0.0 }))
        for index in devices.indices {
            let directory = DeviceDirectories.android(name: devices[index].name, config: config)
            devices[index].directory = directory
            let serial = devices[index].serial
            let runtimeKey = serial.map { adbPath + ":" + $0 }
            let readRuntime: (@Sendable () async throws -> String)?
            if devices[index].state == .running, let serial {
                readRuntime = { [runner] in try await runner.run(adbPath, ["-s", serial, "shell", "getprop"], timeout: 3) }
            } else { readRuntime = nil }
            let info = await metadata.info(directory: directory, sdkRoots: [sdkRoot] + PathDiscovery.sdkRoots, runtimeKey: runtimeKey, readRuntime: readRuntime)
            if !info.detail.isEmpty { devices[index].detail = info.detail }
        }
        return devices
    }

    public func start(_ d: Device, mode: BootMode) async throws {
        let emulatorPath = try emulator(), adbPath = try adb()
        // start-server is idempotent when the ADB server is already running.
        _ = try await runner.run(adbPath, ["start-server"], timeout: 10)
        try await launches.launch(key: d.id, path: emulatorPath, args: EmulatorLaunchArguments.android(name: d.key, mode: mode), environment: config.androidEnvironment)
    }
    public func delete(_ d: Device) async throws {
        try DeviceDeletion.validate(d)
        let root = URL(fileURLWithPath: try emulator()).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent("cmdline-tools")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: tools.path)) ?? []
        let candidates = [tools.appendingPathComponent("latest/bin/avdmanager").path] + versions.sorted().reversed().map { tools.appendingPathComponent($0 + "/bin/avdmanager").path } + [root.appendingPathComponent("tools/bin/avdmanager").path] + PathDiscovery.pathCandidates("avdmanager")
        let manager = try PathDiscovery.resolve("", candidates: candidates)
        _ = try await runner.run(manager, ["delete", "avd", "-n", d.name], environment: config.androidEnvironment, timeout: 60)
    }
    public func stop(_ d: Device) async throws {
        guard let serial = d.serial, serial.hasPrefix("emulator-") else { throw CLIError(L10n.text("缺少模拟器 serial，请刷新")) }
        _ = try await runner.run(adb(), ["-s", serial, "emu", "kill"])
    }
}

public struct HarmonyProvider: DeviceProvider {
    public let platform = Platform.HarmonyOS
    let config: Configuration
    let launches: LaunchManager
    public init(_ config: Configuration, launches: LaunchManager) { self.config = config; self.launches = launches }
    func path() async throws -> String {
        if !config.harmony.isEmpty { return try PathDiscovery.resolve(config.harmony, candidates: []) }
        return try PathDiscovery.resolve("", candidates: await PathDiscovery.harmonyCandidates())
    }
    public func list() async throws -> [Device] { try Parsers.harmony(await ProcessRunner().run(path(), ["-list", "-details"])) }
    public func start(_ d: Device, mode: BootMode) async throws { try await launches.launch(key: d.id, path: path(), args: EmulatorLaunchArguments.harmony(name: d.key, mode: mode)) }
    public func delete(_ d: Device) async throws {
        try DeviceDeletion.validate(d)
        _ = try await ProcessRunner().run(path(), ["-delete", d.key, "-force"], timeout: 60)
    }
    public func stop(_ d: Device) async throws { _ = try await ProcessRunner().run(path(), ["-stop", d.key], timeout: 45) }
}
