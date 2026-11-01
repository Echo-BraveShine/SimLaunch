import Foundation

public struct AndroidSystemInfo: Equatable, Sendable {
    public var release: String?
    public var api: String?
    public var architecture: String?

    public init(release: String? = nil, api: String? = nil, architecture: String? = nil) {
        self.release = release; self.api = api; self.architecture = architecture
    }

    public var detail: String {
        // Only use known stable mappings when the image has no release metadata.
        let releases = ["21": "5.0", "22": "5.1", "23": "6.0", "24": "7.0", "25": "7.1", "26": "8.0", "27": "8.1", "28": "9", "29": "10", "30": "11", "31": "12", "32": "12L", "33": "13", "34": "14", "35": "15", "36": "16"]
        let version = release ?? api.flatMap { releases[$0] }
        return [version.map { "Android " + $0 }, api.map { "API " + $0 }, architecture].compactMap { $0 }.joined(separator: " · ")
    }

    public func overriding(_ fallback: AndroidSystemInfo) -> AndroidSystemInfo {
        var resolvedAPI = api ?? fallback.api
        // getprop on some images only reports the major level; keep a verified minor level.
        if let api, let local = fallback.api, !api.contains("."), local.hasPrefix(api + ".") { resolvedAPI = local }
        let sameAPI = api == nil || api?.split(separator: ".").first == fallback.api?.split(separator: ".").first
        return .init(release: release ?? (sameAPI ? fallback.release : nil), api: resolvedAPI, architecture: architecture ?? fallback.architecture)
    }

    public static func properties(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("["), let separator = line.range(of: "]: ["), line.hasSuffix("]") {
                values[String(line[line.index(after: line.startIndex)..<separator.lowerBound])] = String(line[separator.upperBound..<line.index(before: line.endIndex)])
            } else if let separator = line.firstIndex(of: "=") {
                values[String(line[..<separator]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return values
    }

    public static func fromProperties(_ values: [String: String]) -> AndroidSystemInfo {
        func value(_ keys: [String]) -> String? {
            keys.compactMap { values[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !["unknown", "rel"].contains($0.lowercased()) }
        }
        let validAPI = ["ro.build.version.sdk_full", "ro.system.build.version.sdk_full", "AndroidVersion.ApiLevel", "ro.build.version.sdk", "ro.system.build.version.sdk"].compactMap { values[$0] }.compactMap { candidate -> String? in
            guard candidate.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil,
                  let major = candidate.split(separator: ".").first.flatMap({ Int($0) }), (1...1000).contains(major) else { return nil }
            return candidate
        }.first
        let abi = value(["ro.product.cpu.abi", "ro.product.cpu.abilist", "SystemImage.Abi", "abi.type"])?.split(separator: ",").first.map(String.init)
        let architecture = abi.map { ["arm64-v8a": "arm64", "armeabi-v7a": "arm", "armeabi": "arm"][$0] ?? $0 }
        return .init(release: value(["ro.build.version.release", "ro.system.build.version.release", "AndroidVersion.VersionName", "AndroidVersion.CodeName"]), api: validAPI, architecture: architecture)
    }
}

/// File metadata is invalidated when image/config files change; getprop is cached per connection.
public actor AndroidMetadataCache {
    private struct Entry { let signature: String; let info: AndroidSystemInfo }
    private var local: [String: Entry] = [:]
    private var runtime: [String: Entry] = [:]
    private var retries: [String: Date] = [:]
    public init() {}

    public func retainRuntimeKeys(_ keys: Set<String>) {
        runtime = runtime.filter { keys.contains($0.key) }
        retries = retries.filter { keys.contains($0.key) }
    }

    public func info(directory: String?, sdkRoots: [String], runtimeKey: String? = nil,
                     readRuntime: (@Sendable () async throws -> String)? = nil) async -> AndroidSystemInfo {
        let configURL = directory.map { URL(fileURLWithPath: $0).appendingPathComponent("config.ini") }
        let configText = configURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let config = AndroidSystemInfo.properties(configText)
        let image = config["image.sysdir.1"].map(PathDiscovery.expand)
        let candidates = image.map { path in path.hasPrefix("/") ? [URL(fileURLWithPath: path)] : sdkRoots.map { URL(fileURLWithPath: PathDiscovery.expand($0)).appendingPathComponent(path) } } ?? []
        let imageURL = candidates.first { url in ["build.prop", "source.properties"].contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) } } ?? candidates.first
        let files = [configURL, imageURL?.appendingPathComponent("source.properties"), imageURL?.appendingPathComponent("build.prop")].compactMap { $0 }
        let signature = configText + files.map { url -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.path):\(modified):\(attributes?[.size] ?? 0)"
        }.joined(separator: "|")
        let key = (directory ?? "") + "|" + sdkRoots.joined(separator: "|")
        let configured: AndroidSystemInfo
        if let cached = local[key], cached.signature == signature { configured = cached.info }
        else {
            var values = config
            for url in files.dropFirst(configURL == nil ? 0 : 1) {
                if let text = try? String(contentsOf: url, encoding: .utf8) { values.merge(AndroidSystemInfo.properties(text)) { _, new in new } }
            }
            if values["AndroidVersion.ApiLevel"] == nil, let target = config["target"] ?? image?.components(separatedBy: "/").first(where: { $0.hasPrefix("android-") }) {
                values["AndroidVersion.ApiLevel"] = target.hasPrefix("android-") ? String(target.dropFirst(8)) : target
            }
            configured = AndroidSystemInfo.fromProperties(values)
            local[key] = Entry(signature: signature, info: configured)
        }
        guard let runtimeKey else { return configured }
        if let cached = runtime[runtimeKey], cached.signature == key + signature { return cached.info.overriding(configured) }
        guard let readRuntime, retries[runtimeKey].map({ $0 <= Date() }) ?? true else { return configured }
        do {
            let actual = AndroidSystemInfo.fromProperties(AndroidSystemInfo.properties(try await readRuntime()))
            if actual.release != nil || actual.api != nil {
                runtime[runtimeKey] = Entry(signature: key + signature, info: actual)
                retries.removeValue(forKey: runtimeKey)
                return actual.overriding(configured)
            }
        } catch { /* Version lookup must not hide devices or break lifecycle operations. */ }
        retries[runtimeKey] = Date().addingTimeInterval(30)
        return configured
    }
}
