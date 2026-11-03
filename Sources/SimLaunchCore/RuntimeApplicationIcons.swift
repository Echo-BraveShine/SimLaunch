import Foundation

struct RuntimeApplicationIcon {
    let png: Data
    let label: String?
    static func parse(_ text: String) throws -> RuntimeApplicationIcon {
        guard text.utf8.count <= 3_000_000 else { throw CLIError(L10n.text("Icon helper output is too large.")) }
        let lines = text.components(separatedBy: .newlines)
        let icons = lines.filter { $0.hasPrefix("SIMLAUNCH_ICON:") }
        guard icons.count == 1, let raw = Data(base64Encoded: String(icons[0].dropFirst(15))), let png = ApplicationService.normalizedIcon(raw) else { throw CLIError(L10n.text("Icon helper did not return a decodable image.")) }
        let label = lines.first { $0.hasPrefix("SIMLAUNCH_LABEL:") }.flatMap { Data(base64Encoded: String($0.dropFirst(16))) }.flatMap { String(data: $0, encoding: .utf8) }
        return RuntimeApplicationIcon(png: png, label: ApplicationParsers.clean(label))
    }
    static func parseBatch(_ text: String, expected: Set<String>) throws -> [String: RuntimeApplicationIcon] {
        guard text.utf8.count <= 3_000_000 else { throw CLIError(L10n.text("Icon helper output is too large.")) }
        var results: [String: RuntimeApplicationIcon] = [:], seen = Set<String>()
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("SIMLAUNCH_RECORD:") {
            guard let data = Data(base64Encoded: String(line.dropFirst(17))), data.count <= 524_288,
                  let row = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = row["id"] as? String,
                  expected.contains(id), seen.insert(id).inserted else { throw CLIError(L10n.text("Icon helper returned an unexpected application.")) }
            if row["error"] != nil { continue }
            guard let encoded = row["png"] as? String, let raw = Data(base64Encoded: encoded), let png = ApplicationService.normalizedIcon(raw) else { throw CLIError(L10n.text("Icon helper did not return a decodable image.")) }
            results[id] = RuntimeApplicationIcon(png: png, label: ApplicationParsers.clean(row["label"]))
        }
        guard seen == expected else { throw CLIError(L10n.text("Icon helper returned an incomplete batch.")) }
        return results
    }

}

extension ApplicationService {
    func androidIconKey(_ app: InstalledApplication, user: String) -> String? {
        guard let build = app.build, let revision = app.revision, !revision.isEmpty else { return nil }
        return "android|" + identity + "|" + user + "|" + app.id + "|" + build + "|" + revision + "|" + L10n.language
    }
    func iosIconKey(_ app: InstalledApplication) -> String? {
        guard let revision = app.revision else { return nil }
        return "ios|" + identity + "|" + app.id + "|" + revision + "|" + L10n.language
    }
    static func iconHelper(_ name: String) throws -> URL {
        if let path = Bundle.module.url(forResource: name, withExtension: nil) { return path }
        if let path = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "IconHelpers") { return path }
        throw CLIError(L10n.text("The packaged icon helper is missing."))
    }
    func androidRuntimeIcon(_ app: InstalledApplication, user: String, connection c: DeviceToolConnection) async throws -> RuntimeApplicationIcon {
        guard ApplicationParsers.validIdentifier(app.id), Int(user) != nil else { throw CLIError(L10n.text("Invalid icon target.")) }
        let helper = try Self.iconHelper("android-icon.dex")
        let remote = "/data/local/tmp/simlaunch-icon-" + UUID().uuidString + ".dex"
        let result: Result<RuntimeApplicationIcon, Error>
        do {
            _ = try await self.run(c, ["-s", c.target, "push", helper.path, remote], timeout: 10)
            let output = try await self.run(c, ["-s", c.target, "shell", "CLASSPATH=" + remote, "app_process", "/system/bin", "dev.ekko.simlaunch.AndroidIconExporter", app.id, user], timeout: 12)
            result = .success(try RuntimeApplicationIcon.parse(output))
        } catch { result = .failure(error) }
        // Cleanup is independent of cancellation of the window/query that created this exact file.
        _ = await Task.detached { try? await self.run(c, ["-s", c.target, "shell", "rm", "-f", remote], timeout: 5) }.value
        return try result.get()
    }
    func androidRuntimeIcons(_ apps: [InstalledApplication], user: String, connection c: DeviceToolConnection) async throws -> [String: RuntimeApplicationIcon] {
        guard !apps.isEmpty, apps.count <= 8, apps.allSatisfy({ ApplicationParsers.validIdentifier($0.id) }), Int(user) != nil else { throw CLIError(L10n.text("Invalid icon target.")) }
        let helper = try Self.iconHelper("android-icon.dex")
        let remote = "/data/local/tmp/simlaunch-icon-" + UUID().uuidString + ".dex"
        let result: Result<[String: RuntimeApplicationIcon], Error>
        do {
            _ = try await self.run(c, ["-s", c.target, "push", helper.path, remote], timeout: 10)
            let output = try await self.run(c, ["-s", c.target, "shell", "CLASSPATH=" + remote, "app_process", "/system/bin", "dev.ekko.simlaunch.AndroidIconExporter", "--batch", user] + apps.map(\.id), timeout: 15)
            result = .success(try RuntimeApplicationIcon.parseBatch(output, expected: Set(apps.map(\.id))))
        } catch { result = .failure(error) }
        _ = await Task.detached { try? await self.run(c, ["-s", c.target, "shell", "rm", "-f", remote], timeout: 5) }.value
        return try result.get()
    }
    public func icons(_ apps: [InstalledApplication], snapshot: ApplicationSnapshot, connection c: DeviceToolConnection, force: Bool = false) async -> [InstalledApplication] {
        let started = Date()
        if device.platform == .Android, let user = snapshot.user {
            var result = apps, missing: [InstalledApplication] = []
            for i in result.indices {
                if !force, let key = androidIconKey(result[i], user: user), let cached = await ApplicationIconCache.shared.record(key) {
                    result[i].icon = cached.png; result[i].name = cached.label ?? result[i].name
                } else { missing.append(result[i]) }
            }
            for start in stride(from: 0, to: missing.count, by: 8) {
                guard !Task.isCancelled else { break }
                let batch = Array(missing[start..<min(start + 8, missing.count)])
                let rendered = try? await androidRuntimeIcons(batch, user: user, connection: c)
                for app in batch {
                    guard let i = result.firstIndex(where: { $0.id == app.id }) else { continue }
                    if let icon = rendered?[app.id] {
                        result[i].icon = icon.png; result[i].name = icon.label ?? result[i].name
                        result[i].extra?["Icon source"] = "Android PackageManager / Drawable"
                        if let key = androidIconKey(app, user: user) { await ApplicationIconCache.shared.set(icon.png, key: key, label: icon.label, created: started) }
                    } else if !Task.isCancelled {
                        // A failed batch must retain the original per-app native/APK recovery path.
                        // Some runtimes reject a batch or expose one application only via APK resources.
                        if let recovered = try? await androidMetadata(app, user: user, connection: c, includeSystemResources: true, bypassIconCache: force) {
                            result[i] = recovered
                            if let png = recovered.icon, let key = androidIconKey(recovered, user: user) {
                                await ApplicationIconCache.shared.set(png, key: key, label: recovered.name, created: started)
                            }
                        }
                        if result[i].icon == nil { result[i].addNote("The device did not expose a readable application icon.") }
                    }
                }
            }
            return result
        }
        return await withTaskGroup(of: (Int, InstalledApplication).self) { group in
            for (index, app) in apps.enumerated() {
                group.addTask {
                    if self.device.platform == .iOS {
                        return (index, await self.iosRuntimeIcon(Self.iosMetadata(app), connection: c, useCache: !force))
                    }
                    return (index, await self.harmonyIcon(app, connection: c, useCache: !force))
                }
            }
            var result = apps
            for await (index, app) in group { result[index] = app }
            return result
        }
    }
    func iosRuntimeIcon(_ original: InstalledApplication, connection c: DeviceToolConnection, useCache: Bool = true) async -> InstalledApplication {
        var app = original
        guard app.icon == nil, let bundle = app.bundlePath else { return app }
        let key = iosIconKey(app) ?? ("ios|" + identity + "|" + app.id + "|" + (app.build ?? ""))
        let started = Date()
        if useCache, let cached = await ApplicationIconCache.shared.get(key) {
            app.icon = cached; app.notes?.removeAll { $0 == "No readable standalone icon was found. Asset catalog icons may require platform resource decoding." }
            app.extra?["Icon source"] = "Simulator UIKit"; return app
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SimLaunch-Icon-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let local = directory.appendingPathComponent("ios-icon")
            try FileManager.default.copyItem(at: Self.iconHelper("ios-simulator-icon"), to: local)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: local.path)
            let output = try await run(c, ["simctl", "spawn", c.target, local.path, app.id, bundle], timeout: 12)
            app.icon = try RuntimeApplicationIcon.parse(output).png
            app.notes?.removeAll { $0 == "No readable standalone icon was found. Asset catalog icons may require platform resource decoding." }
            app.extra?["Icon source"] = "Simulator UIKit"
            if let icon = app.icon { await ApplicationIconCache.shared.set(icon, key: key, created: started) }
        } catch { if !Task.isCancelled { app.addNote("The simulator runtime could not decode this icon.") } }
        return app
    }
}
