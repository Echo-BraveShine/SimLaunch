import Foundation

public enum ApplicationKind: String, Codable, Sendable { case user, system, unknown }
public struct InstalledApplication: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var build: String? = nil
    public var revision: String? = nil
    public var notes: [String]? = nil
    public var extra: [String: String]? = nil
    public var version: String?
    public var kind: ApplicationKind = .unknown
    public var removable: Bool? = nil
    public var bundlePath: String? = nil
    public var icon: Data? = nil
    public var displayName: String { name?.isEmpty == false ? name! : id }
    public var canUninstall: Bool { kind == .user && removable != false && ApplicationParsers.validIdentifier(id) }
    public init(id: String, name: String? = nil, version: String? = nil, kind: ApplicationKind = .unknown, removable: Bool? = nil, bundlePath: String? = nil) {
        self.id = id; self.name = name; self.version = version; self.kind = kind; self.removable = removable; self.bundlePath = bundlePath
    }
}
public struct ApplicationSnapshot: Codable, Sendable {
    public var applications: [InstalledApplication]
    public var user: String?
    public var date = Date()
    public init(applications: [InstalledApplication], user: String? = nil) { self.applications = applications; self.user = user }
    public mutating func reusePresentations(from previous: ApplicationSnapshot?) {
        guard let previous, previous.user == user else { return }
        let cached = Dictionary(previous.applications.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for i in applications.indices {
            if let old = cached[applications[i].id] { applications[i] = applications[i].reusingPresentation(old) }
        }
    }
}
public enum ApplicationParsers {
    static func clean(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let text = (value as? String ?? (value as? NSNumber)?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    public static func validIdentifier(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,254}$"#, options: .regularExpression) != nil
    }
    public static func ios(_ text: String) throws -> [InstalledApplication] {
        let data = Data(text.utf8)
        let object = (try? PropertyListSerialization.propertyList(from: data, format: nil)) ?? (try? JSONSerialization.jsonObject(with: data))
        guard let rows = object as? [String: [String: Any]] else { throw CLIError(L10n.text("Cannot parse installed applications.")) }
        return try rows.map { id, row in
            if let declared = row["CFBundleIdentifier"] as? String, declared != id { throw CLIError(L10n.text("Application identifier mismatch.")) }
            let type = row["ApplicationType"] as? String
            let kind: ApplicationKind = type == "User" ? .user : type == "System" ? .system : .unknown
            let bundle = row["Bundle"] as? String
            let path = (row["Path"] as? String) ?? bundle.flatMap { URL(string: $0)?.isFileURL == true ? URL(string: $0)?.path : nil }
            var app = InstalledApplication(id: id, name: clean(row["CFBundleDisplayName"]) ?? clean(row["CFBundleName"]), version: clean(row["CFBundleShortVersionString"]), kind: kind, removable: row["IsRemovable"] as? Bool, bundlePath: path)
            app.build = clean(row["CFBundleVersion"])
            return app
        }.sorted { $0.id < $1.id }
    }
    public static func androidPackages(_ text: String) throws -> Set<String> {
        var ids = Set<String>()
        for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !line.isEmpty {
            guard line.hasPrefix("package:") else { throw CLIError(L10n.text("Cannot parse installed applications.") + " " + String(line.prefix(200))) }
            let id = String(line.dropFirst(8))
            guard validIdentifier(id), ids.insert(id).inserted else { throw CLIError(L10n.text("Cannot parse installed applications.")) }
        }
        return ids
    }
    public static func harmonyList(_ text: String) throws -> ApplicationSnapshot {
        var apps: [InstalledApplication] = [], users = Set<String>(), ids = Set<String>()
        for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !line.isEmpty {
            if line.hasPrefix("ID:"), line.hasSuffix(":"), let id = Int(line.dropFirst(3).dropLast().trimmingCharacters(in: .whitespaces)), id >= 0 { users.insert(String(id)); continue }
            guard validIdentifier(line), line.contains("."), ids.insert(line).inserted else { throw CLIError(L10n.text("Cannot parse installed applications.") + " " + String(line.prefix(200))) }
            apps.append(.init(id: line))
        }
        return ApplicationSnapshot(applications: apps, user: users.count == 1 ? users.first : nil)
    }
    public static func harmonyLabels(_ text: String) throws -> [String: String] {
        guard let rows = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { throw CLIError(L10n.text("Cannot parse installed applications.")) }
        return rows.reduce(into: [:]) { result, row in
            if let id = row["bundleName"] as? String, let label = row["label"] as? String, !label.hasPrefix("$"), !label.isEmpty { result[id] = label }
        }
    }
    public static func harmonyDetails(_ text: String, app: InstalledApplication) throws -> InstalledApplication {
        guard let begin = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), begin <= end,
              let root = try JSONSerialization.jsonObject(with: Data(text[begin...end].utf8)) as? [String: Any],
              root["name"] as? String == app.id, let info = root["applicationInfo"] as? [String: Any] else { throw CLIError(L10n.text("Cannot parse installed applications.")) }
        var result = app
        if let system = info["isSystemApp"] as? Bool { result.kind = system ? .system : .user }
        result.removable = info["removable"] as? Bool
        result.version = clean(root["versionName"]) ?? clean(info["versionName"])
        result.build = clean(root["versionCode"]) ?? clean(info["versionCode"])
        result.bundlePath = clean(info["codePath"])
        result.extra = [:]
        for key in ["minCompatibleVersionCode", "targetVersion", "installTime", "updateTime", "entryModuleName"] { if let value = clean(root[key]) { result.extra?[key] = value } }
        for key in ["apiCompatibleVersion", "apiTargetVersion", "appProvisionType", "appDistributionType", "label", "iconPath", "iconId"] { if let value = clean(info[key]) { result.extra?[key] = value } }
        if let permissions = info["permissions"] as? [String], !permissions.isEmpty { result.extra?["permissions"] = permissions.joined(separator: "\n") }
        result.notes = app.notes
        if let resource = info["iconResource"] as? [String: Any], resource["bundleName"] as? String == app.id,
           let module = resource["moduleName"] as? String, let modules = root["hapModuleInfos"] as? [[String: Any]],
           let selected = modules.first(where: { ($0["moduleName"] as? String ?? $0["name"] as? String) == module }), let hap = selected["hapPath"] as? String {
            result.extra?["iconModule"] = module
            result.extra?["iconHapPath"] = hap
            result.extra?["iconResourceId"] = clean(resource["id"])
        }
        if result.name == nil, let label = info["label"] as? String, !label.hasPrefix("$"), !label.isEmpty { result.name = label }
        if result.name == nil { result.addNote("Application label resources could not be resolved.") }
        result.extra?["Metadata source"] = "bm dump"
        return result
    }
    public static func uninstallSucceeded(_ text: String, platform: Platform) -> Bool {
        switch platform {
        case .iOS: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .Android: return text.trimmingCharacters(in: .whitespacesAndNewlines) == "Success"
        case .HarmonyOS:
            let lower = text.lowercased()
            return lower.contains("uninstall bundle successfully") && !lower.contains("error") && !lower.contains("failed")
        }
    }
}

/// Every list / mutation resolves the selected device again. Shell arguments are fixed or validated IDs.
public struct ApplicationService {
    let device: Device
    let configuration: Configuration
    let identity: String
    private let connector: () async throws -> DeviceToolConnection
    private let execute: (String, [String], [String: String], TimeInterval) async throws -> String
    public init(device: Device, configuration: Configuration, identity: String? = nil) {
        self.device = device; self.configuration = configuration; self.identity = identity ?? LogConnection.fingerprint(device)
        let expected = self.identity
        connector = { try await LogConnection.connection(device: device, configuration: configuration, expectedIdentity: expected) }
        execute = { path, args, env, timeout in try await ProcessRunner().run(path, args, environment: env, timeout: timeout) }
    }
    init(device: Device, connector: @escaping () async throws -> DeviceToolConnection, execute: @escaping (String, [String], [String: String], TimeInterval) async throws -> String) {
        self.device = device; configuration = Configuration(); identity = LogConnection.fingerprint(device); self.connector = connector; self.execute = execute
    }
    func run(_ c: DeviceToolConnection, _ args: [String], timeout: TimeInterval = 15) async throws -> String {
        try Task.checkCancellation()
        return try await execute(c.path, args, c.environment, timeout)
    }
    private func scope(_ c: DeviceToolConnection) async throws -> String {
        let value = try await run(c, ["-s", c.target, "shell", "am", "get-current-user"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(value), number >= 0 else { throw CLIError(L10n.text("Cannot confirm the application user.")) }
        return String(number)
    }
    public func list() async throws -> ApplicationSnapshot { try await list(connector()) }
    private func list(_ connection: DeviceToolConnection) async throws -> ApplicationSnapshot {
        switch device.platform {
        case .iOS:
            return ApplicationSnapshot(applications: try ApplicationParsers.ios(await run(connection, ["simctl", "listapps", connection.target])))
        case .Android:
            let user = try await scope(connection)
            let all = try ApplicationParsers.androidPackages(await run(connection, ["-s", connection.target, "shell", "pm", "list", "packages", "--user", user]))
            let thirdParty = try ApplicationParsers.androidPackages(await run(connection, ["-s", connection.target, "shell", "pm", "list", "packages", "-3", "--user", user]))
            let system = try ApplicationParsers.androidPackages(await run(connection, ["-s", connection.target, "shell", "pm", "list", "packages", "-s", "--user", user]))
            guard try await scope(connection) == user else { throw CLIError(L10n.text("The application user changed. Refresh before continuing.")) }
            return ApplicationSnapshot(applications: all.sorted().map { .init(id: $0, kind: system.contains($0) ? .system : thirdParty.contains($0) ? .user : .unknown) }, user: user)
        case .HarmonyOS:
            var snapshot = try ApplicationParsers.harmonyList(await run(connection, ["-t", connection.target, "shell", "bm", "dump", "-a"]))
            if let text = try? await run(connection, ["-t", connection.target, "shell", "bm", "dump", "-a", "-l"]), let labels = try? ApplicationParsers.harmonyLabels(text) {
                for i in snapshot.applications.indices { snapshot.applications[i].name = labels[snapshot.applications[i].id] }
            }
            return snapshot
        }
    }
    public func metadata(_ app: InstalledApplication, snapshot: ApplicationSnapshot, connection: DeviceToolConnection, loadIcon: Bool = true, bypassIconCache: Bool = false) async throws -> InstalledApplication {
        guard ApplicationParsers.validIdentifier(app.id) else { return app }
        switch device.platform {
        case .iOS:
            var result = Self.iosMetadata(app, loadIcon: loadIcon)
            if loadIcon { return await iosRuntimeIcon(result, connection: connection, useCache: !bypassIconCache) }
            if !bypassIconCache, let key = iosIconKey(result), let cached = await ApplicationIconCache.shared.get(key) { result.icon = cached }
            return result
        case .Android: return try await androidMetadata(app, user: snapshot.user, connection: connection, loadIcon: loadIcon, bypassIconCache: bypassIconCache)
        case .HarmonyOS:
            var args = ["-t", connection.target, "shell", "bm", "dump", "-n", app.id]
            if let user = snapshot.user { args += ["-u", user] }
            var result = try ApplicationParsers.harmonyDetails(await run(connection, args), app: app)
            if app.build != nil && (result.build != app.build || result.extra?["updateTime"] != app.extra?["updateTime"]) { result.icon = nil }
            if loadIcon { return await harmonyIcon(result, connection: connection, useCache: !bypassIconCache) }
            if !bypassIconCache, let key = harmonyIconKey(result), let cached = await ApplicationIconCache.shared.get(key) { result.icon = cached }
            return result
        }
    }
    public func metadataConnection() async throws -> DeviceToolConnection { try await connector() }
    public func details(_ app: InstalledApplication, snapshot: ApplicationSnapshot, forceIcon: Bool = false) async throws -> InstalledApplication {
        let connection = try await connector()
        let fresh = try await list(connection)
        guard fresh.user == snapshot.user else { throw CLIError(L10n.text("The application user changed. Refresh before continuing.")) }
        guard let selected = fresh.applications.first(where: { $0.id == app.id }) else { throw CLIError(L10n.text("This application is no longer installed. Refresh the list.")) }
        let result: InstalledApplication
        if device.platform == .Android { result = try await androidMetadata(selected, user: fresh.user, connection: connection, includeSystemResources: true, bypassIconCache: forceIcon) }
        else { result = try await metadata(selected, snapshot: fresh, connection: connection, bypassIconCache: forceIcon) }
        let verifiedConnection = try await connector()
        guard verifiedConnection.target == connection.target, verifiedConnection.path == connection.path else { throw CLIError(L10n.text("The device connection changed. Refresh before continuing.")) }
        let verified = try await list(verifiedConnection)
        guard verified.user == fresh.user else { throw CLIError(L10n.text("The application user changed. Refresh before continuing.")) }
        guard verified.applications.contains(where: { $0.id == selected.id }) else { throw CLIError(L10n.text("This application is no longer installed. Refresh the list.")) }
        return result
    }
    public func install(_ package: PreparedInstallation, snapshot: ApplicationSnapshot, progress: (String) async -> Void = { _ in }) async throws -> ApplicationSnapshot {
        guard package.platform == device.platform else { throw CLIError(L10n.text("The selected package format is not supported on this device.")) }
        let connection = try await connector(), before = try await list(connection)
        guard before.user == snapshot.user else { throw CLIError(L10n.text("The application user changed. Refresh before continuing.")) }
        if let existing = before.applications.first(where: { $0.id == package.application.id }), !existing.canUninstall {
            throw CLIError(L10n.text("Installing over a system or unverified application is not supported."))
        }
        let verified = try await connector()
        guard verified.path == connection.path, verified.target == connection.target else { throw CLIError(L10n.text("The device connection changed. Refresh before continuing.")) }
        await progress("Installing application…")
        do {
            switch device.platform {
            case .iOS:
                _ = try await run(connection, ["simctl", "install", connection.target, package.files[0].path], timeout: 180)
            case .Android:
                guard let user = before.user, Int(user) != nil else { throw CLIError(L10n.text("Cannot confirm the application user.")) }
                let output = try await run(connection, ["-s", connection.target, package.files.count == 1 ? "install" : "install-multiple", "-r", "-t", "--user", user] + package.files.map(\.path), timeout: 180)
                guard output.range(of: #"(?m)^\s*Success\s*$"#, options: .regularExpression) != nil else { throw CLIError(String(output.prefix(3000))) }
            case .HarmonyOS:
                guard let user = before.user, Int(user) != nil else { throw CLIError(L10n.text("Cannot confirm the application user.")) }
                let remote = "/data/local/tmp/simlaunch-install-" + UUID().uuidString
                _ = try await run(connection, ["-t", connection.target, "shell", "mkdir", "-p", remote])
                let result: Result<Void, Error>
                do {
                    var paths: [String] = []
                    for (i, file) in package.files.enumerated() {
                        let path = remote + "/package-\(i).hap"
                        let transfer = try await run(connection, ["-t", connection.target, "file", "send", file.path, path], timeout: 120)
                        guard !transfer.contains("[Fail]") else { throw CLIError(String(transfer.prefix(3000))) }; paths.append(path)
                    }
                    let current = try await list(connection), active = try await connector()
                    guard current.user == user, active.path == connection.path, active.target == connection.target else { throw CLIError(L10n.text("The device connection changed. Refresh before continuing.")) }
                    let output = try await run(connection, ["-t", connection.target, "shell", "bm", "install", "-p"] + paths + ["-r", "-u", user], timeout: 180)
                    guard output.lowercased().contains("successfully"), !output.lowercased().contains("failed") else { throw CLIError(String(output.prefix(3000))) }
                    result = .success(())
                } catch { result = .failure(error) }
                _ = await Task.detached { try? await self.run(connection, ["-t", connection.target, "shell", "rm", "-rf", remote], timeout: 10) }.value
                try result.get()
            }
            await progress("Verifying installation…")
            let latestConnection = try await connector()
            guard latestConnection.target == connection.target, latestConnection.path == connection.path else { throw CLIError(L10n.text("The device connection changed. Refresh before continuing.")) }
            let after = try await list(latestConnection)
            guard after.user == before.user, let found = after.applications.first(where: { $0.id == package.application.id }) else { throw CLIError(L10n.text("Installation could not be verified. Refresh the application list.")) }
            let metadata = try await metadata(found, snapshot: after, connection: latestConnection, loadIcon: false, bypassIconCache: true)
            guard metadata.build == package.application.build else { throw CLIError(L10n.text("Installation could not be verified. Refresh the application list.")) }
            return after
        } catch {
            throw CLIError(L10n.text("Installation failed or its result is uncertain. Refresh before retrying.") + "\n" + error.localizedDescription)
        }
    }
    public func uninstall(_ app: InstalledApplication, snapshot: ApplicationSnapshot) async throws -> ApplicationSnapshot {
        guard app.canUninstall else { throw CLIError(L10n.text("Only confirmed user applications can be uninstalled.")) }
        let connection = try await connector()
        let current = try await list(connection)
        guard current.user == snapshot.user else { throw CLIError(L10n.text("The application user changed. Refresh before continuing.")) }
        guard let found = current.applications.first(where: { $0.id == app.id }) else { throw CLIError(L10n.text("This application is no longer installed. Refresh the list.")) }
        let confirmed: InstalledApplication
        if device.platform == .HarmonyOS {
            var args = ["-t", connection.target, "shell", "bm", "dump", "-n", found.id]
            if let user = current.user { args += ["-u", user] }
            confirmed = try ApplicationParsers.harmonyDetails(await run(connection, args), app: found)
        }
        else { confirmed = found }
        guard confirmed.canUninstall else { throw CLIError(L10n.text("Only confirmed user applications can be uninstalled.")) }
        let fresh = try await connector()
        guard fresh.target == connection.target, fresh.path == connection.path else { throw CLIError(L10n.text("The device connection changed. Refresh before continuing.")) }
        let args: [String]
        switch device.platform {
        case .iOS: args = ["simctl", "uninstall", fresh.target, app.id]
        case .Android:
            guard let user = current.user, try await scope(fresh) == user else { throw CLIError(L10n.text("The application user changed. Refresh before continuing.")) }
            args = ["-s", fresh.target, "shell", "pm", "uninstall", "--user", user, app.id]
        case .HarmonyOS:
            guard let user = current.user else { throw CLIError(L10n.text("Cannot confirm the application user.")) }
            let latest = try ApplicationParsers.harmonyList(await run(fresh, ["-t", fresh.target, "shell", "bm", "dump", "-a"]))
            guard latest.user == user else { throw CLIError(L10n.text("The application user changed. Refresh before continuing.")) }
            args = ["-t", fresh.target, "shell", "bm", "uninstall", "-n", app.id, "-u", user]
        }
        let output = try await run(fresh, args, timeout: 60)
        guard ApplicationParsers.uninstallSucceeded(output, platform: device.platform) else { throw CLIError(L10n.text("Uninstall failed.") + " " + String(output.prefix(2000))) }
        let verified = try await list()
        guard verified.user == current.user, !verified.applications.contains(where: { $0.id == app.id }) else { throw CLIError(L10n.text("Uninstall could not be verified. Refresh the application list.")) }
        return verified
    }
}

extension InstalledApplication {
    mutating func addNote(_ note: String) {
        if notes == nil { notes = [] }
        if notes?.contains(note) == false { notes?.append(note) }
    }
    public func reusingPresentation(_ cached: InstalledApplication) -> InstalledApplication {
        // A different declared version/build must never inherit the previous icon or name.
        guard id == cached.id, (version == nil || version == cached.version), (build == nil || build == cached.build) else { return self }
        var result = self
        result.name = name ?? cached.name; result.icon = icon ?? cached.icon
        result.version = version ?? cached.version; result.build = build ?? cached.build
        result.revision = revision ?? cached.revision
        return result
    }
}
