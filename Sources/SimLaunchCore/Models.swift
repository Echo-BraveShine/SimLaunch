import Foundation

public enum Platform: String, Codable, CaseIterable, Identifiable { case iOS, Android, HarmonyOS; public var id: String { rawValue } }
public enum DeviceState: String { case stopped = "已停止", running = "运行中", starting = "启动中", unavailable = "不可用", unknown = "状态未知" }
public enum DeviceBackend: String { case standard, mumu }
public struct Device: Identifiable {
    public var backend: DeviceBackend = .standard
    public var isOfflineSnapshot = false
    public var supportsColdBoot: Bool { platform != .iOS && backend != .mumu }
    public var id: String { platform.rawValue + ":" + (backend == .mumu ? "MuMu:" : "") + key }
    public let platform: Platform
    public let key: String
    public let name: String
    public var state: DeviceState
    public var detail: String
    public var directory: String? = nil
    public var serial: String?
    public var instanceID: String? = nil
    public init(platform: Platform, key: String, name: String, state: DeviceState, detail: String = "", serial: String? = nil) {
        self.platform = platform; self.key = key; self.name = name; self.state = state; self.detail = detail; self.serial = serial
    }
}
public struct Configuration: Codable, Equatable {
    public var developerDir = ""
    public var simulatorApp: String? = nil
    public var emulator = ""
    public var adb = ""
    public var harmony = ""
    public var avdHome = ""
    public var hdc: String? = nil
    public var mumuTool: String? = nil
    public init() {}
    public var iosEnvironment: [String: String] { developerDir.isEmpty ? [:] : ["DEVELOPER_DIR": PathDiscovery.expand(developerDir)] }
    public var androidEnvironment: [String: String] { avdHome.isEmpty ? [:] : ["ANDROID_AVD_HOME": PathDiscovery.expand(avdHome)] }
}
public enum PathDiscovery {
    public static func expand(_ value: String) -> String { (value as NSString).expandingTildeInPath }
    public static func resolve(_ override: String, candidates: [String]) throws -> String {
        let paths = override.isEmpty ? candidates : [override]
        for value in paths where isExecutableFile(expand(value)) { return expand(value) }
        throw CLIError(L10n.format("Executable not found. Configure its path in Settings. %@", override))
    }
    static func isExecutableFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
    public static func pathCandidates(_ executable: String) -> [String] {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + executable }
    }
    public static var sdkRoots: [String] {
        let env = ProcessInfo.processInfo.environment
        return [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], "~/Library/Android/sdk"].compactMap { $0 }.filter { !$0.isEmpty }
    }
    public static func simulatorCandidates(developerDir: String) -> [String] {
        let developer = URL(fileURLWithPath: developerDir)
        return [developer.appendingPathComponent("Applications/Simulator.app").path,
                developer.deletingLastPathComponent().appendingPathComponent("Applications/Simulator.app").path,
                developer.deletingLastPathComponent().appendingPathComponent("Applications/DeviceHub.app").path,
                developer.appendingPathComponent("Applications/DeviceHub.app").path]
    }
    public static func simulatorOpenArguments(path: String, udid: String) -> [String] {
        if URL(fileURLWithPath: path).lastPathComponent == "DeviceHub.app" || Bundle(path: path)?.bundleIdentifier == "com.apple.dt.Devices" {
            var url = URLComponents()
            url.scheme = "devices"; url.host = "device"; url.path = "/open"
            url.queryItems = [URLQueryItem(name: "id", value: udid)]
            return ["-a", path, url.string!]
        }
        return ["-a", path, "--args", "-CurrentDeviceUDID", udid]
    }
    public static func resolveSimulator(_ override: String?, candidates: [String]) throws -> String {
        let manual = override.map(expand).flatMap { $0.isEmpty ? nil : $0 }
        for path in manual.map({ [$0] }) ?? candidates {
            // Xcode 27 DeviceHub uses DevicesTrampoline, not a binary named Simulator.
            let infoURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
            let info = (try? Data(contentsOf: infoURL)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            let executable = info?["CFBundleExecutable"] as? String ?? "Simulator"
            guard !executable.contains("/"), executable != ".", executable != ".." else { continue }
            if isExecutableFile(path + "/Contents/MacOS/" + executable) { return path }
        }
        throw CLIError(L10n.format("Simulator.app or DeviceHub.app not found. Check the selected Xcode or specify an app path in Settings. Searched: %@", (manual.map { [$0] } ?? candidates).joined(separator: ", ")))
    }
    public static func harmonyCandidates() async -> [String] {
        var apps = ["/Applications/DevEco-Studio.app", "~/Applications/DevEco-Studio.app"]
        if let output = try? await ProcessRunner().run("/usr/bin/mdfind", ["kMDItemFSName == '*DevEco*.app'cd"], timeout: 5) {
            apps += output.split(separator: "\n").map(String.init)
        }
        return apps.map { $0 + "/Contents/tools/emulator/Emulator" } + pathCandidates("Emulator")
    }
}
public enum BootMode { case normal, cold }

public protocol DeviceProvider {
    var platform: Platform { get }
    func list() async throws -> [Device]
    func start(_ device: Device, mode: BootMode) async throws
    func delete(_ device: Device) async throws
    func stop(_ device: Device) async throws
}

public extension DeviceProvider {
    func start(_ device: Device) async throws { try await start(device, mode: .normal) }
}

public enum EmulatorLaunchArguments {
    public static func android(name: String, mode: BootMode) -> [String] {
        ["-avd", name] + (mode == .cold ? ["-no-snapshot-load"] : [])
    }
    public static func harmony(name: String, mode: BootMode) -> [String] {
        ["-start", name] + (mode == .cold ? ["-bootMode", "coldboot"] : [])
    }
}
