import Foundation
import CryptoKit

/// Presentation cache only. Keys include the device, user and verified package revision.
actor ApplicationIconCache {
    struct Record: Codable, Sendable { let png: Data; let label: String?; let created: Date }
    static let shared = ApplicationIconCache()
    private let directory: URL
    private let diskLimit: Int
    private var values: [String: Record] = [:]
    private var order: [String] = []
    private var lastPrune = Date.distantPast
    init(directory: URL? = nil, diskLimit: Int = 52_428_800) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dev.ekko.simlaunch/ApplicationIcons-v2")
        self.diskLimit = diskLimit
    }
    private func url(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(("icon-v2|" + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    func get(_ key: String) -> Data? { record(key)?.png }
    func record(_ key: String) -> Record? {
        if let value = values[key], Date().timeIntervalSince(value.created) < 2_592_000 {
            order.removeAll { $0 == key }; order.append(key); return value
        }
        let path = url(key)
        guard let attributes = try? path.resourceValues(forKeys: [.fileSizeKey]), (attributes.fileSize ?? Int.max) <= 524_288,
              let data = try? Data(contentsOf: path), let value = try? JSONDecoder().decode(Record.self, from: data),
              (-60...2_592_000).contains(Date().timeIntervalSince(value.created)), value.png.count <= 262_144,
              IconRasterizer.image(value.png) != nil else { values.removeValue(forKey: key); return nil }
        remember(value, key: key); return value
    }
    func set(_ icon: Data, key: String, label: String? = nil, created: Date = Date()) {
        guard icon.count <= 262_144 else { return }
        guard values[key].map({ $0.created <= created }) ?? true else { return }
        let value = Record(png: icon, label: label.map { String($0.prefix(1024)) }, created: created)
        remember(value, key: key)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(value).write(to: url(key), options: .atomic)
            prune()
        } catch { /* A read-only/full cache must never hide a successfully decoded icon. */ }
    }
    private func remember(_ value: Record, key: String) {
        values[key] = value; order.removeAll { $0 == key }; order.append(key)
        while order.count > 128 || values.values.reduce(0, { $0 + $1.png.count }) > 8_388_608 { values.removeValue(forKey: order.removeFirst()) }
    }
    private func prune() {
        guard Date().timeIntervalSince(lastPrune) > 30 else { return }; lastPrune = Date()
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []).filter { $0.pathExtension == "json" }
        var entries = files.map { path -> (URL, Int, Date) in
            let info = try? path.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (path, info?.fileSize ?? 0, info?.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var total = 0
        for (index, item) in entries.enumerated() {
            total += item.1
            if index >= 512 || total > diskLimit || Date().timeIntervalSince(item.2) > 2_592_000 { try? FileManager.default.removeItem(at: item.0) }
        }
        entries.removeAll()
    }
}
