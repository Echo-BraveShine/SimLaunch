import Foundation

public extension Configuration {
    func usesAutomaticPaths(for platform: Platform) -> Bool {
        switch platform {
        case .iOS: return developerDir.isEmpty && (simulatorApp ?? "").isEmpty
        case .Android: return emulator.isEmpty && adb.isEmpty && avdHome.isEmpty
        case .HarmonyOS: return harmony.isEmpty && (hdc ?? "").isEmpty
        }
    }

    mutating func useAutomaticPaths(for platform: Platform) {
        switch platform {
        case .iOS: developerDir = ""; simulatorApp = nil
        case .Android: emulator = ""; adb = ""; avdHome = ""
        case .HarmonyOS: harmony = ""; hdc = nil
        }
    }

    /// Validate only explicit overrides. Missing optional development environments
    /// must not prevent users from saving settings for another platform.
    func validateManualPaths() throws {
        func invalid(_ field: String, _ path: String) -> CLIError {
            CLIError(L10n.format("Invalid path for %@: %@", field, path))
        }
        if !developerDir.isEmpty {
            let directory = URL(fileURLWithPath: PathDiscovery.expand(developerDir))
            // xcrun accepts either Contents/Developer or the enclosing Xcode.app.
            let tools = ["usr/bin/simctl", "Contents/Developer/usr/bin/simctl"]
            guard tools.contains(where: { PathDiscovery.isExecutableFile(directory.appendingPathComponent($0).path) }) else {
                throw invalid(L10n.text("Xcode 开发者目录"), developerDir)
            }
        }
        if let app = simulatorApp, !app.isEmpty {
            _ = try PathDiscovery.resolveSimulator(app, candidates: [])
        }
        for (field, path) in [("Android Emulator", emulator), ("Android ADB", adb), ("HarmonyOS Emulator", harmony), ("HarmonyOS HDC", hdc ?? "")] where !path.isEmpty {
            guard PathDiscovery.isExecutableFile(PathDiscovery.expand(path)) else { throw invalid(field, path) }
        }
        if !avdHome.isEmpty {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: PathDiscovery.expand(avdHome), isDirectory: &directory), directory.boolValue else {
                throw invalid(L10n.text("虚拟设备目录"), avdHome)
            }
        }
    }
}
