import Foundation
import ImageIO

extension ApplicationService {
    static func smallFile(_ url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 2_097_152 else { return nil }
        return try? Data(contentsOf: url)
    }
    static func normalizedIcon(_ data: Data) -> Data? {
        IconRasterizer.normalized(data)
    }
    static func iosMetadata(_ original: InstalledApplication, loadIcon: Bool = true) -> InstalledApplication {
        var app = original
        guard let path = app.bundlePath, path.hasPrefix("/") else { app.addNote("Application bundle path is unavailable."); return app }
        let bundle = URL(fileURLWithPath: path)
        guard let data = smallFile(bundle.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { app.addNote("Application Info.plist is unreadable."); return app }
        guard info["CFBundleIdentifier"] as? String == app.id else { app.addNote("Application identifier mismatch."); app.icon = nil; return app }
        app.version = ApplicationParsers.clean(info["CFBundleShortVersionString"]) ?? app.version
        app.build = ApplicationParsers.clean(info["CFBundleVersion"]) ?? app.build
        app.extra = ["Metadata source": "simctl / Info.plist"]
        for key in ["MinimumOSVersion", "CFBundleExecutable", "CFBundleDevelopmentRegion", "DTPlatformName", "DTSDKName"] { if let value = ApplicationParsers.clean(info[key]) { app.extra?[key] = value } }
        let languages = L10n.language.hasPrefix("zh") ? ["zh-Hans", "zh_CN", "zh", "en", "Base"] : ["en", "en-US", "Base"]
        var localized: [String: Any] = [:]
        for language in languages {
            if let data = smallFile(bundle.appendingPathComponent(language + ".lproj/InfoPlist.strings")), let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               ApplicationParsers.clean(values["CFBundleDisplayName"]) != nil || ApplicationParsers.clean(values["CFBundleName"]) != nil { localized = values; break }
        }
        app.name = ApplicationParsers.clean(localized["CFBundleDisplayName"]) ?? ApplicationParsers.clean(localized["CFBundleName"]) ?? ApplicationParsers.clean(info["CFBundleDisplayName"]) ?? ApplicationParsers.clean(info["CFBundleName"]) ?? app.name
        let icons = (info["CFBundleIcons"] as? [String: Any]) ?? (info["CFBundleIcons~ipad"] as? [String: Any])
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let declared = (primary?["CFBundleIconFiles"] as? [String] ?? []) + (info["CFBundleIconFiles"] as? [String] ?? []) + [info["CFBundleIconFile"] as? String].compactMap { $0 }
        let names = Array(declared.reversed()) + ["AppIcon60x60", "AppIcon", "Icon"]
        let asset = bundle.appendingPathComponent("Assets.car")
        let attributes = try? FileManager.default.attributesOfItem(atPath: asset.path)
        let infoAttributes = try? FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent("Info.plist").path)
        let individual = names.flatMap { name in [name, name + "@3x.png", name + "@2x.png", name + ".png"] }.map { name -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent(name).path)
            return name + ":" + String((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) + ":" + String(describing: attributes?[.size])
        }.joined(separator: "|")
        let revision = (app.build ?? "") + "|" + path + "|" + String((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) + "|" + String(describing: attributes?[.size]) + "|" + String((infoAttributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) + "|" + individual
        if app.revision != revision { app.icon = nil }
        app.revision = revision
        guard loadIcon else { return app }
        app.icon = nil
        for name in names where !name.contains("/") && name != ".." {
            let candidates = name.hasSuffix(".png") || name.hasSuffix(".icns") ? [name] : [name + "@3x.png", name + "@2x.png", name + ".png", name]
            for candidate in candidates {
                if let data = smallFile(bundle.appendingPathComponent(candidate)), let normalized = normalizedIcon(data) { app.icon = normalized; app.extra?["Icon source"] = "Application bundle image"; return app }
            }
        }
        app.addNote("No readable standalone icon was found. Asset catalog icons may require platform resource decoding.")
        return app
    }
    static func aaptPath() -> String? {
        var candidates = PathDiscovery.pathCandidates("aapt2")
        for root in PathDiscovery.sdkRoots {
            let directory = URL(fileURLWithPath: PathDiscovery.expand(root)).appendingPathComponent("build-tools")
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += versions.map { directory.appendingPathComponent($0 + "/aapt2").path }
        }
        return try? PathDiscovery.resolve("", candidates: candidates)
    }
    static func badging(_ text: String, app: InstalledApplication) -> (InstalledApplication, String?) {
        var app = app, labels: [String: String] = [:], icons: [(Int, String)] = []
        func unescape(_ value: String) -> String {
            value.replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: "\\\\", with: "\\")
        }
        func attribute(_ line: String, _ key: String) -> String? {
            let pattern = NSRegularExpression.escapedPattern(for: key) + #"='((?:\\.|[^'\\])*)'"#
            guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
            return unescape(String(line[range]).dropFirst(key.count + 2).dropLast().description)
        }
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("package:") {
                guard let identifier = attribute(line, "name"), identifier == app.id else {
                    app.addNote("Application identifier mismatch."); app.icon = nil; return (app, nil)
                }
                if let low = attribute(line, "versionCode"), let value = UInt64(low) {
                    if let major = attribute(line, "versionCodeMajor").flatMap(UInt64.init), major <= UInt64(UInt32.max) { app.build = String((major << 32) | (value & 0xFFFFFFFF)) }
                    else if app.build == nil { app.build = low }
                }
                app.version = ApplicationParsers.clean(attribute(line, "versionName"))
            }
            if line.hasPrefix("application-label"), let separator = line.range(of: ":'") , line.hasSuffix("'") {
                labels[String(line[..<separator.lowerBound])] = unescape(String(line[separator.upperBound...].dropLast()))
            }
            // APKs with literal labels (rather than resource labels) use this form.
            if line.hasPrefix("application:") {
                if let label = attribute(line, "label") { labels["application-label"] = label }
                if let range = line.range(of: #"icon='([^']+)'"#, options: .regularExpression) {
                    let path = String(line[range]).dropFirst(6).dropLast().description
                    if ["png", "webp", "jpg", "jpeg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") { icons.append((160, path)) }
                }
            }
            if line.hasPrefix("application-icon-"), let separator = line.range(of: ":'"), line.hasSuffix("'") {
                let density = Int(line.dropFirst(17).prefix(while: { $0.isNumber })) ?? 0
                let path = String(line[separator.upperBound...].dropLast())
                if ["png", "webp", "jpg", "jpeg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") { icons.append((density, path)) }
            }
        }
        let preferred = L10n.language.hasPrefix("zh") ? ["application-label-zh-CN", "application-label-zh", "application-label"] : ["application-label-en", "application-label-en-US", "application-label"]
        if let label = preferred.compactMap({ labels[$0] }).first(where: { !$0.isEmpty }) { app.name = label }
        return (app, icons.sorted { abs($0.0 - 160) < abs($1.0 - 160) }.first?.1)
    }
    static func androidDump(_ text: String, app original: InstalledApplication) -> InstalledApplication {
        var app = original
        let lines = text.components(separatedBy: .newlines)
        let marker = "Package [" + app.id + "]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(marker) }) else {
            app.version = nil; app.build = nil; app.revision = nil; app.extra = nil
            app.addNote("Package metadata could not be read."); return app
        }
        var values: [String: String] = [:]
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Package [") { break }
            for key in ["versionName", "versionCode", "codePath", "firstInstallTime", "lastUpdateTime", "minSdk", "targetSdk"] where trimmed.hasPrefix(key + "=") {
                let value = String(trimmed.dropFirst(key.count + 1))
                if values[key] == nil { values[key] = key == "versionCode" || key == "minSdk" || key == "targetSdk" ? String(value.prefix(while: { $0.isNumber })) : value }
            }
        }
        app.version = ApplicationParsers.clean(values["versionName"]).flatMap { $0 == "null" ? nil : $0 }
        app.build = ApplicationParsers.clean(values["versionCode"])
        app.bundlePath = ApplicationParsers.clean(values["codePath"])
        app.revision = [values["versionCode"], values["lastUpdateTime"], values["codePath"]].compactMap { $0 }.joined(separator: "|")
        if app.revision?.isEmpty == true { app.revision = nil }
        app.extra = values.filter { !["versionName", "versionCode", "codePath"].contains($0.key) }
        app.extra?["Metadata source"] = "dumpsys package / APK"
        return app
    }
    func androidMetadata(_ app: InstalledApplication, user: String?, connection c: DeviceToolConnection, includeSystemResources: Bool = false, loadIcon: Bool = true, bypassIconCache: Bool = false) async throws -> InstalledApplication {
        guard let user else { return app }
        let runner = ProcessRunner()
        let started = Date()
        var app = app
        app.notes = nil
        if let dump = try? await run(c, ["-s", c.target, "shell", "dumpsys", "package", app.id], timeout: 6) {
            let parsed = Self.androidDump(dump, app: app)
            let unchanged = app.revision != nil && app.revision == parsed.revision && app.build == parsed.build
            app = parsed
            if !bypassIconCache && unchanged && app.icon != nil && app.name != nil { return app }
            app.icon = nil; app.name = nil
        } else { app.addNote("Package metadata could not be read."); app.icon = nil; app.name = nil; app.revision = nil }
        if !bypassIconCache, let key = androidIconKey(app, user: user), let cached = await ApplicationIconCache.shared.record(key) {
            app.icon = cached.png; app.name = cached.label ?? app.name
            app.extra?["Icon source"] = "Verified icon cache"
        }
        guard loadIcon else { return app }
        if app.icon != nil && app.name != nil { return app }
        if let rendered = try? await androidRuntimeIcon(app, user: user, connection: c) {
            app.icon = rendered.png; app.name = rendered.label ?? app.name
            app.extra?["Icon source"] = "Android PackageManager / Drawable"
            if let key = androidIconKey(app, user: user) { await ApplicationIconCache.shared.set(rendered.png, key: key, label: rendered.label, created: started) }
            return app
        }
        if app.kind == .system && !includeSystemResources { app.addNote("System application resources are loaded when opening details."); return app }
        guard let aapt = Self.aaptPath() else { app.addNote("AAPT2 is unavailable. Name and icon extraction requires Android SDK Build Tools."); return app }
        let output = try await runner.run(c.path, ["-s", c.target, "shell", "pm", "path", "--user", user, app.id], timeout: 8)
        let paths = output.components(separatedBy: .newlines).filter { $0.hasPrefix("package:/") }.map { String($0.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let path = paths.first(where: { $0.hasSuffix("/base.apk") }) ?? paths.first else { app.addNote("Application APK path is unavailable."); return app }
        app.bundlePath = path
        // adb shell joins arguments remotely. Quote device-provided file paths explicitly.
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let sizeText = try await runner.run(c.path, ["-s", c.target, "shell", "stat", "-c", "%s", quoted], timeout: 5)
        guard let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines)), size > 0, size <= 67_108_864 else { app.addNote("APK size is unavailable or exceeds the 64 MiB metadata limit."); return app }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SimLaunch-App-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apk = directory.appendingPathComponent("base.apk").path
        _ = try await runner.run(c.path, ["-s", c.target, "pull", path, apk], timeout: 20)
        let text = try await runner.run(aapt, ["dump", "badging", apk], timeout: 10)
        var (enriched, iconPath) = Self.badging(text, app: app)
        if let iconPath, let data = try? await runner.runData("/usr/bin/unzip", ["-p", apk, iconPath], timeout: 5), let normalized = Self.normalizedIcon(data) { enriched.icon = normalized }
        if enriched.icon == nil { enriched.addNote("Neither native rendering nor APK bitmap extraction produced an icon.") }
        if enriched.name == nil { enriched.addNote("Application label resources could not be resolved.") }
        return enriched
    }
}

/// Short-lived in-memory snapshots only. Mutations always require a fresh list and device identity.
public actor ApplicationCache {
    public static let shared = ApplicationCache()
    private var entries: [String: ApplicationSnapshot] = [:]
    private var order: [String] = []
    public func get(_ key: String) -> ApplicationSnapshot? { entries[key] }
    public func set(_ snapshot: ApplicationSnapshot, for key: String) {
        var bounded = snapshot, bytes = 0
        for i in bounded.applications.indices {
            bytes += bounded.applications[i].icon?.count ?? 0
            if bytes > 10_485_760 { bounded.applications[i].icon = nil }
        }
        entries[key] = bounded; order.removeAll { $0 == key }; order.append(key)
        while order.count > 4 { entries.removeValue(forKey: order.removeFirst()) }
    }
    public func remove(_ key: String) { entries.removeValue(forKey: key); order.removeAll { $0 == key } }
}
