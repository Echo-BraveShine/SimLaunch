import Foundation

public struct DeviceInformationField: Identifiable, Sendable {
    public let id: String
    public let value: String
    public let isPath: Bool
    public init(_ key: String, _ value: String, path: Bool = false) { id = key; self.value = value; isPath = path }
}
public struct DeviceInformationSection: Identifiable, Sendable {
    public let id: String
    public let source: String
    public let fields: [DeviceInformationField]
    public init(_ title: String, source: String, fields: [DeviceInformationField]) { id = title; self.source = source; self.fields = fields }
}
public struct DeviceInformationRaw: Identifiable, Sendable {
    public let id: String
    public let text: String
}
public struct DeviceInformation: Sendable {
    public var sections: [DeviceInformationSection] = []
    public var raw: [DeviceInformationRaw] = []
    public var warnings: [String] = []
    public var date = Date()
    public init() {}
    public func report() -> String {
        var lines = ["SimLaunch · " + L10n.text("Device information"), ISO8601DateFormatter().string(from: date)]
        for section in sections {
            lines += ["", "[" + L10n.text(section.id) + "]", L10n.text("Source") + ": " + section.source]
            lines += section.fields.map { L10n.text($0.id) + ": " + $0.value }
        }
        lines += warnings.map { "\n⚠ " + $0 }
        for item in raw { lines += ["\n[" + item.id + "]", item.text] }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum DeviceInformationReader {
    public static func properties(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else { continue }
            let pair = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { values[String(pair[0]).trimmingCharacters(in: .whitespaces)] = String(pair[1]).trimmingCharacters(in: .whitespaces) }
        }
        return values
    }
    public static func fields(_ object: [String: Any]) -> [DeviceInformationField] {
        object.keys.sorted().compactMap { key in
            guard let value = object[key], !(value is NSNull) else { return nil }
            let string: String
            if let value = value as? String { string = value }
            else if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { string = String(decoding: data, as: UTF8.self) }
            else { string = String(describing: value) }
            guard !string.isEmpty else { return nil }
            return DeviceInformationField(key, string, path: string.hasPrefix("/") && !string.contains("\n"))
        }
    }
    public static func iosSelection(_ text: String, udid: String) throws -> (device: [String: Any], runtime: [String: Any], type: [String: Any]) {
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let groups = root["devices"] as? [String: [[String: Any]]] else { throw CLIError(L10n.text("Cannot parse device information.")) }
        for (runtimeID, rows) in groups {
            if var row = rows.first(where: { $0["udid"] as? String == udid }) {
                row["runtimeIdentifier"] = runtimeID
                let runtimes = root["runtimes"] as? [[String: Any]] ?? []
                let types = root["devicetypes"] as? [[String: Any]] ?? []
                return (row, runtimes.first { $0["identifier"] as? String == runtimeID } ?? [:], types.first { $0["identifier"] as? String == row["deviceTypeIdentifier"] as? String } ?? [:])
            }
        }
        throw CLIError(L10n.text("Device identity changed. Reopen device information from the device list."))
    }
    public static func read(device: Device, configuration config: Configuration, expectedIdentity: String? = nil) async -> DeviceInformation {
        var result = DeviceInformation()
        result.sections.append(.init("Basic information", source: L10n.text("Device list snapshot"), fields: [
            .init("Device name", device.name), .init("Platform", device.platform.rawValue), .init("Device state", L10n.text(device.state.rawValue)), .init("System version / availability", device.detail), .init("Device identifier", device.key)
        ]))
        if let directory = device.directory { result.sections.append(.init("Device paths", source: L10n.text("Device list snapshot"), fields: [.init("Instance / data directory", directory, path: true)])) }
        guard LogConnection.fingerprint(device) == (expectedIdentity ?? LogConnection.fingerprint(device)) else {
            result.warnings.append(L10n.text("Device identity changed. Reopen device information from the device list.")); return result
        }
        let runner = ProcessRunner()
        func query(_ name: String, _ path: String, _ arguments: [String], environment: [String: String] = [:]) async -> String? {
            guard !Task.isCancelled else { return nil }
            do { return try await runner.run(path, arguments, environment: environment, timeout: 12) }
            catch { if !Task.isCancelled { result.warnings.append(name + ": " + error.localizedDescription) }; return nil }
        }
        var refreshedState = device.state
        func currentState(_ state: DeviceState) {
            refreshedState = state
            let fields = result.sections[0].fields.map { $0.id == "Device state" ? DeviceInformationField("Device state", L10n.text(state.rawValue)) : $0 }
            result.sections[0] = .init("Basic information", source: L10n.text("Selected device query"), fields: fields)
        }
        func add(_ title: String, source: String, object: [String: Any]) {
            guard !object.isEmpty else { return }
            result.sections.append(.init(title, source: source, fields: fields(object)))
            let text = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? String(describing: object)
            result.raw.append(.init(id: source, text: text))
        }
        func file(_ path: String) -> String? {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else { result.warnings.append(L10n.text("Configuration file exceeds 1 MiB.") + " " + path); return nil }
            return String(data: data, encoding: .utf8)
        }
        switch device.platform {
        case .iOS:
            if let output = await query("simctl list", "/usr/bin/xcrun", ["simctl", "list", "--json"], environment: config.iosEnvironment) {
                do {
                    let selected = try iosSelection(output, udid: device.key)
                    let state = selected.device["state"] as? String ?? ""
                    currentState((selected.device["isAvailable"] as? Bool) == false ? .unavailable : state == "Booted" ? .running : state == "Shutdown" ? .stopped : .starting)
                    add("Device configuration", source: "simctl · device", object: selected.device)
                    add("System runtime", source: "simctl · runtime", object: selected.runtime)
                    add("Device type", source: "simctl · device type", object: selected.type)
                } catch { result.warnings.append(error.localizedDescription) }
            }
            var tools: [String: Any] = [:]
            if let path = await query("simctl", "/usr/bin/xcrun", ["--find", "simctl"], environment: config.iosEnvironment) { tools["simctl"] = path.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let version = await query("Xcode", "/usr/bin/xcodebuild", ["-version"], environment: config.iosEnvironment) { tools["Xcode"] = version.trimmingCharacters(in: .whitespacesAndNewlines) }
            add("Development environment", source: "xcrun / xcodebuild", object: tools)
        case .Android:
            if device.backend == .mumu {
                let provider = MuMuProvider(config)
                do {
                    guard let fresh = try await provider.list().first(where: { $0.id == device.id }),
                          LogConnection.fingerprint(fresh) == (expectedIdentity ?? LogConnection.fingerprint(device)) else {
                        throw CLIError(L10n.text("Cannot confirm the selected device connection."))
                    }
                    currentState(fresh.state)
                    if fresh.isOfflineSnapshot {
                        add("Device configuration", source: L10n.text("MuMu local catalog"), object: ["index": fresh.key, "name": fresh.name, "bundle_path": fresh.directory ?? ""])
                    } else {
                        let output = try await provider.rawList()
                        guard let selected = try MuMuProvider.parse(output).first(where: { $0.id == fresh.id }),
                              LogConnection.fingerprint(selected) == LogConnection.fingerprint(fresh),
                              let row = try MuMuProvider.rows(output).first(where: { String(describing: $0["index"] ?? "") == device.key }) else {
                            throw CLIError(L10n.text("Cannot confirm the selected device connection."))
                        }
                        add("Device configuration", source: "mumutool info", object: row)
                    }
                    if let directory = fresh.directory, let text = file(directory + "/setting/vm.json"),
                       let data = text.data(using: .utf8), let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        add("MuMu settings", source: "MuMu · vm.json", object: settings)
                    }
                    if let path = try? await provider.path() {
                        var tools: [String: Any] = ["mumutool": path]
                        if let version = await query("mumutool", path, ["--version"]) { tools["CLI version"] = version.trimmingCharacters(in: .whitespacesAndNewlines) }
                        add("Development environment", source: "MuMu", object: tools)
                    }
                    if fresh.state == .running {
                        let (connected, adb) = try await provider.connectedDevice(fresh, expectedIdentity: expectedIdentity)
                        if let serial = connected.serial, let text = await query("getprop", adb, ["-s", serial, "shell", "getprop"]) {
                            var values: [String: String] = [:]
                            for line in text.components(separatedBy: .newlines) {
                                let pair = line.components(separatedBy: "]: [")
                                if pair.count == 2 { values[String(pair[0].dropFirst())] = String(pair[1].dropLast()) }
                            }
                            add("Runtime properties", source: "MuMu · adb getprop", object: values)
                        }
                    }
                } catch { if !Task.isCancelled { result.warnings.append(error.localizedDescription) } }
            } else {
            let provider = AndroidProvider(config, launches: LaunchManager())
            var tools: [String: Any] = [:]
            if let emulator = try? provider.emulator() {
                tools["emulator"] = emulator
                tools["SDK"] = URL(fileURLWithPath: emulator).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().path
                if let version = await query("emulator", emulator, ["-version"]) { tools["Emulator version"] = String(version.prefix(4000)) }
            } else { result.warnings.append(L10n.text("Emulator tool not found.")) }
            if let directory = device.directory ?? DeviceDirectories.android(name: device.name, config: config), let text = file(directory + "/config.ini") {
                let configuration = properties(text)
                add("Device configuration", source: directory + "/config.ini", object: configuration)
                if let image = configuration["image.sysdir.1"], image.hasPrefix("/") || tools["SDK"] != nil {
                    let path = image.hasPrefix("/") ? image : URL(fileURLWithPath: tools["SDK"] as! String).appendingPathComponent(image).standardizedFileURL.path
                    result.sections.append(.init("System image", source: "config.ini + SDK", fields: [.init("System image directory", path, path: true)]))
                    if let text = file(URL(fileURLWithPath: path).appendingPathComponent("source.properties").path) {
                        add("System image metadata", source: path + "/source.properties", object: properties(text))
                    }
                }
            } else { result.warnings.append(L10n.text("Device configuration file is unavailable.")) }
            if let adb = try? provider.adb() {
                tools["adb"] = adb
                if let version = await query("adb", adb, ["version"]) { tools["ADB version"] = version.trimmingCharacters(in: .whitespacesAndNewlines) }
                do {
                        let fresh = try await provider.list().first { $0.id == device.id }
                        guard let fresh, LogConnection.fingerprint(fresh) == (expectedIdentity ?? LogConnection.fingerprint(device)) else { throw CLIError(L10n.text("Cannot confirm the selected device connection.")) }
                        currentState(fresh.state)
                        if fresh.state == .running, let serial = fresh.serial {
                        add("Runtime information", source: "adb · " + serial, object: ["serial": serial])
                        if let text = await query("getprop", adb, ["-s", serial, "shell", "getprop"]) {
                            var values: [String: String] = [:]
                            for line in text.components(separatedBy: .newlines) {
                                let pair = line.components(separatedBy: "]: [")
                                if pair.count == 2 { values[String(pair[0].dropFirst())] = String(pair[1].dropLast()) }
                            }
                            let keys = ["ro.product.model", "ro.product.manufacturer", "ro.product.cpu.abilist", "ro.build.version.release", "ro.build.version.sdk", "ro.build.fingerprint", "sys.boot_completed"]
                            add("Runtime properties", source: "adb getprop · " + serial, object: values.filter { keys.contains($0.key) })
                            result.raw.append(.init(id: "adb getprop (all) · " + serial, text: text))
                        }
                        }
                } catch { if !Task.isCancelled { result.warnings.append(error.localizedDescription) } }
            } else { result.warnings.append(L10n.text("ADB tool not found.")) }
            add("Development environment", source: "Android SDK", object: tools)
            }
        case .HarmonyOS:
            let provider = HarmonyProvider(config, launches: LaunchManager())
            var tools: [String: Any] = [:]
            if let path = try? await provider.path() {
                tools["Emulator"] = path
                if let output = await query("Emulator -list -details", path, ["-list", "-details"]) {
                    do {
                        guard let begin = output.firstIndex(of: "["), let end = output.lastIndex(of: "]"), begin <= end,
                              let rows = try JSONSerialization.jsonObject(with: Data(output[begin...end].utf8)) as? [[String: Any]], let row = rows.first(where: { $0["name"] as? String == device.key }),
                              device.instanceID == nil || row["uuid"] as? String == device.instanceID else { throw CLIError(L10n.text("Cannot confirm the selected device connection.")) }
                        let running = String(describing: row["isRunning"] ?? "unknown").lowercased()
                        currentState(["true", "1"].contains(running) ? .running : ["false", "0"].contains(running) ? .stopped : .unknown)
                        add("Device configuration", source: "Emulator -list -details", object: row)
                    } catch { result.warnings.append(error.localizedDescription) }
                }
                if let version = await query("Emulator version", path, ["-version"]) { tools["Emulator version"] = version.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else { result.warnings.append(L10n.text("Emulator tool not found.")) }
            if let hdc = try? await LogConnection.hdcPath(config) {
                tools["HDC"] = hdc
                if let version = await query("HDC version", hdc, ["-v"]) { tools["HDC version"] = version.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            add("Development environment", source: "DevEco Studio", object: tools)
        }
        if refreshedState != .running { result.warnings.append(L10n.text("Runtime-only information requires a running device. The device has not been started.")) }
        result.date = Date()
        return result
    }
}
