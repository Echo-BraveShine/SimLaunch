import Foundation

public enum LogConnection {
    public static func fingerprint(_ device: Device) -> String {
        var parts = [device.id, device.instanceID ?? ""]
        if let directory = device.directory,
           let attrs = try? FileManager.default.attributesOfItem(atPath: directory) {
            parts += [directory, String(describing: attrs[.systemFileNumber] ?? ""), String(describing: attrs[.creationDate] ?? "")]
        }
        return parts.joined(separator: "|")
    }
    public static func hdcPath(_ config: Configuration) async throws -> String {
        if let manual = config.hdc, !manual.isEmpty { return try PathDiscovery.resolve(manual, candidates: []) }
        var candidates: [String] = []
        if let emulator = try? await HarmonyProvider(config, launches: LaunchManager()).path() {
            let contents = URL(fileURLWithPath: emulator).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(contents.appendingPathComponent("sdk/default/openharmony/toolchains/hdc").path)
        }
        candidates += ["/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc", "~/Library/Huawei/Sdk/openharmony/toolchains/hdc"] + PathDiscovery.pathCandidates("hdc")
        return try PathDiscovery.resolve("", candidates: candidates)
    }
    /// Never choose the first connected HDC target. Match the emulator's live port or UUID.
    public static func harmonyTarget(row: [String: Any], connected: [String], runtimeTargets: [String] = []) throws -> String {
        var expected = Set(runtimeTargets)
        if let uuid = row["uuid"] as? String { expected.insert(uuid) }
        if let value = row["hw.hdc.port"], let port = Int(String(describing: value)), (1...65535).contains(port) {
            expected.formUnion(["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"])
        }
        let matches = Set(connected).intersection(expected)
        guard matches.count == 1, let target = matches.first else {
            throw CLIError(L10n.text("Cannot match this emulator to an HDC connection. Refresh the device or check the HDC tool in Settings."))
        }
        return target
    }
    public static func command(device: Device, configuration config: Configuration, expectedIdentity: String? = nil) async throws -> LogCommand {
        let runner = ProcessRunner()
        switch device.platform {
        case .iOS:
            let devices = try await IOSProvider(config).list()
            try validate(device, current: devices, expectedIdentity: expectedIdentity)
            return LogCommand(path: "/usr/bin/xcrun", arguments: ["simctl", "spawn", device.key, "log", "stream", "--style", "compact", "--level", "debug"], environment: config.iosEnvironment, target: device.key)
        case .Android:
            let provider = AndroidProvider(config, launches: LaunchManager())
            let devices = try await provider.list()
            let fresh = try validate(device, current: devices, expectedIdentity: expectedIdentity)
            guard let serial = fresh.serial, serial.hasPrefix("emulator-") else { throw CLIError(L10n.text("Missing emulator serial. Refresh the device list.")) }
            return LogCommand(path: try provider.adb(), arguments: ["-s", serial, "logcat", "-v", "threadtime"], target: serial)
        case .HarmonyOS:
            let path = try await HarmonyProvider(config, launches: LaunchManager()).path()
            let text = try await runner.run(path, ["-list", "-details"])
            let current = try Parsers.harmony(text)
            _ = try validate(device, current: current, expectedIdentity: expectedIdentity)
            guard let first = text.firstIndex(of: "["), let last = text.lastIndex(of: "]"), first <= last,
                  let rows = try JSONSerialization.jsonObject(with: Data(text[first...last].utf8)) as? [[String: Any]],
                  let row = rows.first(where: { $0["name"] as? String == device.key }) else { throw CLIError(L10n.text("设备已消失，请刷新")) }
            let hdc = try await hdcPath(config)
            let targets = try await runner.run(hdc, ["list", "targets"])
            let connected = targets.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0 != "[Empty]" }
            let runtime = (try? await HarmonyLogTarget.targets(executable: path, name: device.key, directory: device.directory)) ?? []
            try Task.checkCancellation()
            let target = try harmonyTarget(row: row, connected: connected, runtimeTargets: runtime)
            return LogCommand(path: hdc, arguments: ["-t", target, "shell", "hilog"], target: target)
        }
    }
    @discardableResult private static func validate(_ original: Device, current: [Device], expectedIdentity: String?) throws -> Device {
        guard let fresh = current.first(where: { $0.id == original.id }), fingerprint(fresh) == (expectedIdentity ?? fingerprint(original)) else {
            throw CLIError(L10n.text("The device was removed or recreated. Open a new log window from the device list."))
        }
        guard fresh.state == .running else { throw CLIError(L10n.text("Start the simulator and wait until it is connected before collecting logs.")) }
        return fresh
    }
}
