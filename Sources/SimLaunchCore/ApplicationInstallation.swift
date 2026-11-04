import Foundation

/// Own a private copy so the files confirmed by the user are the files installed.
public final class PreparedInstallation: Identifiable {
    public let id = UUID()
    public let application: InstalledApplication
    public let files: [URL]
    public let fileNames: [String]
    public let bytes: Int64
    public let platform: Platform
    private let directory: URL
    init(application: InstalledApplication, files: [URL], fileNames: [String], bytes: Int64, platform: Platform, directory: URL) {
        self.application = application; self.files = files; self.fileNames = fileNames
        self.bytes = bytes; self.platform = platform; self.directory = directory
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

public enum ApplicationInstaller {
    public static func prepare(_ urls: [URL], platform: Platform) async throws -> PreparedInstallation {
        guard !urls.isEmpty, urls.count <= 32, Set(urls.map { $0.standardizedFileURL }).count == urls.count,
              platform != .iOS || urls.count == 1 else { throw CLIError(L10n.text("Select one application and all of its required packages.")) }
        let ext = platform == .iOS ? "app" : platform == .Android ? "apk" : "hap"
        guard urls.allSatisfy({ $0.isFileURL && $0.pathExtension.lowercased() == ext }) else { throw CLIError(L10n.text("The selected package format is not supported on this device.")) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SimLaunch-Install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        var files: [URL] = [], bytes: Int64 = 0
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let sourceInfo = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard sourceInfo.isSymbolicLink != true, (ext == "app" ? sourceInfo.isDirectory == true : sourceInfo.isRegularFile == true) else { throw CLIError(L10n.text("The selected package format is not supported on this device.")) }
            let copy = directory.appendingPathComponent("package-\(index)." + ext)
            // Copy work stays off the UI actor, including large simulator application bundles.
            try await Task.detached { try FileManager.default.copyItem(at: url, to: copy) }.value
            files.append(copy)
            if ext == "app" {
                let enumerator = FileManager.default.enumerator(at: copy, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
                while let item = enumerator?.nextObject() as? URL {
                    let info = try item.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                    if info.isSymbolicLink == true && !item.resolvingSymlinksInPath().path.hasPrefix(copy.path + "/") { throw CLIError(L10n.text("The application contains a link outside its bundle.")) }
                    bytes += Int64(info.fileSize ?? 0)
                }
            } else { bytes += Int64(try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        }
        let runner = ProcessRunner()
        var apps: [InstalledApplication] = [], modules = Set<String>(), bases = 0
        for file in files {
            try Task.checkCancellation()
            if platform == .iOS {
                let data = try Data(contentsOf: file.appendingPathComponent("Info.plist"))
                guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let identifier = info["CFBundleIdentifier"] as? String, let executable = info["CFBundleExecutable"] as? String,
                      !executable.contains("/"), executable != ".." else { throw CLIError(L10n.text("The application package metadata is invalid.")) }
                let binary = file.appendingPathComponent(executable).path
                let arches = try await runner.run("/usr/bin/lipo", [binary, "-archs"])
                #if arch(arm64)
                let architecture = "arm64"
                #else
                let architecture = "x86_64"
                #endif
                guard arches.split(whereSeparator: \.isWhitespace).contains(Substring(architecture)) else { throw CLIError(L10n.text("This simulator application does not support this Mac's architecture.")) }
                let load = try await runner.run("/usr/bin/otool", ["-arch", architecture, "-l", binary])
                guard load.range(of: #"platform\s+(7|IOSSIMULATOR)\b"#, options: .regularExpression) != nil || (architecture == "x86_64" && load.contains("LC_VERSION_MIN_IPHONEOS")) else { throw CLIError(L10n.text("Choose an application built for iOS Simulator, not a physical device.")) }
                var app = InstalledApplication(id: identifier, name: ApplicationParsers.clean(info["CFBundleDisplayName"]) ?? ApplicationParsers.clean(info["CFBundleName"]), version: ApplicationParsers.clean(info["CFBundleShortVersionString"]))
                app.build = ApplicationParsers.clean(info["CFBundleVersion"]); apps.append(app)
            } else if platform == .Android {
                guard let aapt = ApplicationService.aaptPath() else { throw CLIError(L10n.text("APK validation requires Android SDK Build Tools (AAPT2).")) }
                let text = try await runner.run(aapt, ["dump", "badging", file.path], timeout: 30)
                let package = text.components(separatedBy: .newlines).first { $0.hasPrefix("package:") } ?? ""
                func attribute(_ key: String) -> String? {
                    guard let range = package.range(of: NSRegularExpression.escapedPattern(for: key) + "='[^']*'", options: .regularExpression) else { return nil }
                    return String(package[range].dropFirst(key.count + 2).dropLast())
                }
                guard let identifier = attribute("name") else { throw CLIError(L10n.text("The application package metadata is invalid.")) }
                var app = InstalledApplication(id: identifier); app.build = attribute("versionCode")
                app = ApplicationService.badging(text, app: app).0; apps.append(app)
                let split = attribute("split") ?? ""
                if split.isEmpty { bases += 1 }
                guard modules.insert(split).inserted else { throw CLIError(L10n.text("Duplicate modules or split packages were selected.")) }
            } else {
                let listing = try await runner.run("/usr/bin/unzip", ["-l", file.path, "module.json"])
                guard let line = listing.components(separatedBy: .newlines).first(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix("module.json") }),
                      let size = Int(line.split(whereSeparator: \.isWhitespace).first ?? ""), size > 0, size <= 2_097_152 else { throw CLIError(L10n.text("The application package metadata is invalid.")) }
                let data = try await runner.runData("/usr/bin/unzip", ["-p", file.path, "module.json"])
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let info = json["app"] as? [String: Any],
                      let identifier = info["bundleName"] as? String, let module = json["module"] as? [String: Any], let name = module["name"] as? String else { throw CLIError(L10n.text("The application package metadata is invalid.")) }
                guard modules.insert(name).inserted else { throw CLIError(L10n.text("Duplicate modules or split packages were selected.")) }
                if module["type"] as? String == "entry" { bases += 1 }
                var app = InstalledApplication(id: identifier, version: ApplicationParsers.clean(info["versionName"])); app.build = ApplicationParsers.clean(info["versionCode"]); apps.append(app)
            }
        }
        guard let first = apps.first, ApplicationParsers.validIdentifier(first.id), first.build != nil,
              apps.allSatisfy({ $0.id == first.id && $0.build == first.build && $0.version == first.version }),
              platform == .iOS || bases == 1 else { throw CLIError(L10n.text("Select matching packages for one application, including exactly one base or entry package.")) }
        retained = true
        return PreparedInstallation(application: first, files: files, fileNames: urls.map(\.lastPathComponent), bytes: bytes, platform: platform, directory: directory)
    }
}
