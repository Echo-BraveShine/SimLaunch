import Foundation

/// MuMu's vms/<index> symlinks are its authoritative on-disk instance catalog.
/// Follow those links instead of guessing indices from .mad filenames or scanning old backups.
enum MuMuCatalog {
    static func read(root: URL, state: DeviceState) throws -> [Device] {
        let vms = root.appendingPathComponent("vms", isDirectory: true)
        guard FileManager.default.fileExists(atPath: vms.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: vms, includingPropertiesForKeys: nil)
            .sorted { (Int($0.lastPathComponent) ?? Int.max) < (Int($1.lastPathComponent) ?? Int.max) }
            .compactMap { link in
                guard let index = Int(link.lastPathComponent), index >= 0, String(index) == link.lastPathComponent else { return nil }
                let directory = link.resolvingSymlinksInPath()
                let settings = directory.appendingPathComponent("setting/vm.json")
                guard let size = try? settings.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                      let data = try? Data(contentsOf: settings),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = json["vmName"] as? String, !name.isEmpty else { return nil }
                var device = Device(platform: .Android, key: String(index), name: name, state: state, detail: "MuMu · Android")
                device.backend = .mumu
                device.isOfflineSnapshot = true
                device.directory = directory.path
                device.instanceID = directory.path
                // Stored ports can be stale; live ADB targets must come from mumutool.
                return device
            }
    }
}
