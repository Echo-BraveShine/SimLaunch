import Foundation

public enum DeviceDeletion {
    public static func validate(_ device: Device) throws {
        guard device.state == .stopped || (device.platform == .iOS && device.state == .unavailable) else {
            throw CLIError(L10n.text("请先停止设备，确认状态后再删除"))
        }
    }
}
public enum DeviceDirectories {
    public static func android(name: String, config: Configuration, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard !name.contains("/"), name != ".", name != ".." else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userHome = environment["ANDROID_USER_HOME"] ?? environment["ANDROID_EMULATOR_HOME"] ?? home + "/.android"
        let avdHome = PathDiscovery.expand(config.avdHome.isEmpty ? (environment["ANDROID_AVD_HOME"] ?? userHome + "/avd") : config.avdHome)
        let ini = URL(fileURLWithPath: avdHome).appendingPathComponent(name + ".ini")
        if let text = try? String(contentsOf: ini, encoding: .utf8) {
            var values: [String: String] = [:]
            for line in text.components(separatedBy: .newlines) {
                let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { values[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces) }
            }
            if let path = values["path"], path.hasPrefix("/") { return path }
            if let relative = values["path.rel"] { return URL(fileURLWithPath: PathDiscovery.expand(userHome)).appendingPathComponent(relative).standardizedFileURL.path }
        }
        let fallback = URL(fileURLWithPath: avdHome).appendingPathComponent(name + ".avd").path
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }
}
