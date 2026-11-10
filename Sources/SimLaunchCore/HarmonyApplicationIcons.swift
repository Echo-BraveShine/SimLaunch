import Foundation

struct HarmonyIconResourceTable {
    let resources: [[String: Any]]
    let module: String
    init(_ text: String, bundle: String, module: String) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], root["bundleName"] as? String == bundle,
              root["moduleName"] as? String == module, let resources = root["resource"] as? [[String: Any]] else { throw CLIError(L10n.text("HAP resource identity mismatch.")) }
        self.resources = resources; self.module = module
    }
    func path(reference: String) -> String? {
        let name = reference.hasPrefix("$media:") ? String(reference.dropFirst(7)) : reference
        let item = resources.first { row in
            guard row["type"] as? String == "media" else { return false }
            if let id = UInt32(name) { return (row["id"] as? NSNumber)?.uint32Value == id }
            return row["name"] as? String == name
        }
        guard let entries = item?["entryValues"] as? [[String: Any]] else { return nil }
        let preferred = entries.sorted { a, b in
            func score(_ value: [String: Any]) -> Int {
                let language = value["language"] as? String
                return language == nil ? 10 : L10n.language.hasPrefix(language!) ? 20 : 0
            }
            return score(a) > score(b)
        }
        guard var path = preferred.first?["value"] as? String else { return nil }
        if path.hasPrefix(module + "/") { path = String(path.dropFirst(module.count + 1)) }
        return Self.safeEntry(path) ? path : nil
    }
    static func safeEntry(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && !path.contains("\n") && !path.split(separator: "/").contains("..")
    }
}

extension ApplicationService {
    private func harmonyIconReference(_ app: InstalledApplication) -> String? {
        if let reference = app.extra?["iconResourceId"], let id = UInt32(reference), id > 0 { return reference }
        return app.extra?["iconPath"]
    }

    func harmonyIconKey(_ app: InstalledApplication) -> String? {
        guard let build = app.build else { return nil }
        return "harmony|" + identity + "|" + app.id + "|" + build + "|" + (app.extra?["updateTime"] ?? "") + "|" + (app.extra?["iconHapPath"] ?? "") + "|" + (app.extra?["iconResourceId"] ?? "") + "|" + L10n.language
    }
    private func restoolPath() async throws -> String {
        var candidates: [String] = []
        if let hdc = try? await LogConnection.hdcPath(configuration) { candidates.append(URL(fileURLWithPath: hdc).deletingLastPathComponent().appendingPathComponent("restool").path) }
        candidates += ["/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/restool"] + PathDiscovery.pathCandidates("restool")
        return try PathDiscovery.resolve("", candidates: candidates)
    }
    private func harmonyImageLocations() async throws -> (sdk: URL, instance: URL?) {
        let provider = HarmonyProvider(configuration, launches: LaunchManager())
        let text = try await ProcessRunner().run(provider.path(), ["-list", "-details"], timeout: 8)
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start <= end,
              let rows = try JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [[String: Any]],
              let selected = rows.first(where: { $0["name"] as? String == device.key && (device.instanceID == nil || $0["uuid"] as? String == device.instanceID) }),
              let root = selected["imageRoot"] as? String, let sub = selected["imageSubPath"] as? String,
              !sub.hasPrefix("/"), !sub.split(separator: "/").contains("..") else { throw CLIError(L10n.text("SDK image location is unavailable.")) }
        let sdk = URL(fileURLWithPath: PathDiscovery.expand(root)).appendingPathComponent(sub)
        let instance: URL?
        if device.instanceID != nil, let path = selected["instancePath"] as? String, path.hasPrefix("/"), path == device.directory {
            instance = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            instance = nil
        }
        return (sdk, instance)
    }

    private func copySDKHap(remote: String, to archive: URL) async throws {
        let directory = try await harmonyImageLocations().sdk
        let operation = Task.detached(priority: .utility) {
            let paths = [remote, "/" + remote.split(separator: "/").dropFirst().joined(separator: "/")]
            for image in ["system.img", "sys_prod.img", "vendor.img"] {
                try Task.checkCancellation()
                guard let reader = try? Ext4ImageReader(url: directory.appendingPathComponent(image)) else { continue }
                for path in paths {
                    do {
                        try reader.copyFile(at: path, to: archive)
                        return
                    } catch Ext4ImageReader.Failure.tooLarge {
                        throw CLIError(L10n.text("The HAP exceeds the icon reader's package size limit."))
                    } catch is Ext4ImageReader.Failure {
                        continue
                    }
                }
            }
            throw CLIError(L10n.text("No matching SDK system package."))
        }
        try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
    }

    private func copyInstalledHap(_ app: InstalledApplication, remote: String, user: String?, connection: DeviceToolConnection, to archive: URL) async throws {
        let prefix = "/data/app/el1/bundle/public/\(app.id)/"
        let filename = String(remote.dropFirst(prefix.count))
        guard ApplicationParsers.validIdentifier(app.id), remote.hasPrefix(prefix),
              !filename.utf8.contains(47), filename.hasSuffix(".hap"), HarmonyIconResourceTable.safeEntry(filename),
              let user, let id = Int(user), id >= 0, String(id) == user,
              let revision = app.extra?["updateTime"] else {
            throw CLIError(L10n.text("The installed HAP cannot be located in the simulator disk."))
        }
        let locations = try await harmonyImageLocations()
        guard let instance = locations.instance else {
            throw CLIError(L10n.text("The installed HAP cannot be located in the simulator disk."))
        }
        let overlay = instance.appendingPathComponent("userdata.img.qcow2")
        let backing = locations.sdk.appendingPathComponent("userdata.img")
        let operation = Task.detached(priority: .utility) {
            let image = try Ext4ImageReader(qcow2URL: overlay, backingURL: backing)
            do {
                try image.copyFile(at: String(remote.dropFirst("/data".count)), to: archive, limit: 512 * 1024 * 1024)
            } catch Ext4ImageReader.Failure.tooLarge {
                throw CLIError(L10n.text("The HAP exceeds the icon reader's package size limit."))
            }
        }
        try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
        // The guest may replace the file while we read its disk. Verify the installed revision before using the archive.
        let args = ["-t", connection.target, "shell", "bm", "dump", "-n", app.id, "-u", user]
        let fresh = try ApplicationParsers.harmonyDetails(await run(connection, args, timeout: 8), app: app)
        guard fresh.extra?["updateTime"] == revision, fresh.version == app.version,
              harmonyIconKey(fresh) == harmonyIconKey(app) else {
            throw CLIError(L10n.text("The installed application changed while reading its icon. Refresh and try again."))
        }
    }
    private func hapEntry(_ path: String, archive: URL) async throws -> Data {
        guard HarmonyIconResourceTable.safeEntry(path) else { throw CLIError(L10n.text("Invalid HAP resource path.")) }
        let listing = try await ProcessRunner().run("/usr/bin/unzip", ["-l", archive.path, path], timeout: 5)
        guard let line = listing.components(separatedBy: .newlines).first(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix(path) }),
              let length = Int(line.split(whereSeparator: \.isWhitespace).first ?? ""), length <= 2_097_152 else { throw CLIError(L10n.text("HAP image resource is too large or missing.")) }
        return try await ProcessRunner().runData("/usr/bin/unzip", ["-p", archive.path, path], timeout: 5)
    }
    private func resolveHarmonyIcon(_ reference: String, table: HarmonyIconResourceTable, archive: URL, seen: Set<String> = []) async throws -> Data {
        guard seen.count < 8, !seen.contains(reference), let path = table.path(reference: reference) else { throw CLIError(L10n.text("HAP icon resource cannot be resolved.")) }
        let data = try await hapEntry(path, archive: archive)
        if let png = IconRasterizer.normalized(data) { return png }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let layers = object["layered-image"] as? [String: String],
              let background = layers["background"], let foreground = layers["foreground"] else { throw CLIError(L10n.text("HAP icon format is unsupported.")) }
        let next = seen.union([reference])
        let back = try await resolveHarmonyIcon(background, table: table, archive: archive, seen: next)
        let front = try await resolveHarmonyIcon(foreground, table: table, archive: archive, seen: next)
        guard let composed = IconRasterizer.composite(background: back, foreground: front) else { throw CLIError(L10n.text("Layered icon rendering failed.")) }
        return composed
    }
    static func matchingHarmonyModule(_ data: Data, app: InstalledApplication, module: String) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let definition = json["app"] as? [String: Any], let info = json["module"] as? [String: Any] else { return false }
        return definition["bundleName"] as? String == app.id && cleanVersion(definition["versionCode"]) == app.build &&
            cleanVersion(definition["versionName"]) == app.version && info["name"] as? String == module
    }
    private static func cleanVersion(_ value: Any?) -> String? { ApplicationParsers.clean(value) }
    private func decodeHarmonyHAP(_ original: InstalledApplication, archive: URL, source: String) async throws -> InstalledApplication {
        var app = original
        guard let module = app.extra?["iconModule"], let reference = harmonyIconReference(app) else { throw CLIError(L10n.text("The HAP icon location is unavailable.")) }
        let started = Date(), moduleData = try await hapEntry("module.json", archive: archive)
        guard Self.matchingHarmonyModule(moduleData, app: app, module: module) else { throw CLIError(L10n.text("The HAP does not match the installed application's bundle, version or module.")) }
        let dump = try await ProcessRunner().run(restoolPath(), ["dump", archive.path], timeout: 15)
        let table = try HarmonyIconResourceTable(dump, bundle: app.id, module: module)
        app.icon = try await resolveHarmonyIcon(reference, table: table, archive: archive)
        app.extra?["Icon source"] = source; app.extra?.removeValue(forKey: "Icon diagnostic")
        app.notes?.removeAll { $0 == "The device does not allow reading this application's HAP. Its icon cannot be extracted without access to the matching installation package." || $0 == "The HAP is protected, unavailable, mismatched, or its icon format is unsupported." }
        if let icon = app.icon, let key = harmonyIconKey(app) { await ApplicationIconCache.shared.set(icon, key: key, created: started) }
        return app
    }
    func harmonyIcon(_ original: InstalledApplication, user: String?, connection c: DeviceToolConnection, useCache: Bool = true) async -> InstalledApplication {
        var app = original
        guard harmonyIconReference(app) != nil else { app.addNote("This HarmonyOS app does not declare an icon."); return app }
        guard let remote = app.extra?["iconHapPath"], remote.hasPrefix("/"), app.extra?["iconModule"] != nil,
              app.build != nil else { app.addNote("The HAP icon location is unavailable."); return app }
        let key = harmonyIconKey(app)!
        let cached = await ApplicationIconCache.shared.record(key)
        if useCache, let cached { app.icon = cached.png; app.extra?["Icon source"] = "Verified HAP icon cache"; return app }
        let runner = ProcessRunner(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("SimLaunch-HAP-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let archive = directory.appendingPathComponent("icon.hap")
            let quoted = "'" + remote.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let size = try? await runner.run(c.path, ["-t", c.target, "shell", "stat", "-c", "%s", quoted], timeout: 5)
            var source = "HDC HAP resources"
            let bytes = size.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            var diagnostic = ApplicationParsers.clean(size) ?? "HDC could not read the installed HAP."
            if let bytes, bytes > 0, bytes <= Ext4ImageReader.archiveLimit {
                do {
                    let output = try await runner.run(c.path, ["-t", c.target, "file", "recv", remote, archive.path], timeout: 30)
                    let file = try? archive.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if file?.isRegularFile != true || file?.fileSize != bytes {
                        diagnostic = ApplicationParsers.clean(output) ?? "HDC could not read the installed HAP."
                        if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
                    }
                } catch {
                    try Task.checkCancellation()
                    diagnostic = error.localizedDescription
                    if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
                }
            } else if let bytes, bytes > Ext4ImageReader.archiveLimit {
                diagnostic = "The HAP exceeds the icon reader's package size limit."
            }
            if !FileManager.default.fileExists(atPath: archive.path) {
                if !remote.hasPrefix("/system/") && !remote.hasPrefix("/sys_prod/") && !remote.hasPrefix("/vendor/") {
                    do {
                        try await copyInstalledHap(app, remote: remote, user: user, connection: c, to: archive)
                        source = "Installed simulator disk (read-only)"
                    } catch {
                        try Task.checkCancellation()
                        app.addNote("The device does not allow reading this application's HAP. Its icon cannot be extracted without access to the matching installation package.")
                        app.extra?["Icon diagnostic"] = diagnostic + "\n" + error.localizedDescription
                        if let cached { app.icon = cached.png; app.extra?["Icon source"] = "Verified HAP icon cache" }
                        return app
                    }
                } else {
                    try await copySDKHap(remote: remote, to: archive)
                    source = "Matching SDK system image (read-only)"
                }
            }
            return try await decodeHarmonyHAP(app, archive: archive, source: source)
        } catch { if !Task.isCancelled { app.addNote("The HAP is protected, unavailable, mismatched, or its icon format is unsupported."); app.extra?["Icon diagnostic"] = error.localizedDescription } }
        return app
    }
}
