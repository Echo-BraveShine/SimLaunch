import Foundation

struct MuMuServiceUnavailable: LocalizedError {
    var errorDescription: String? { L10n.text("MuMu manager unavailable") }
}
struct MuMuCommandError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { "MuMu (\(code)): \(message)" }
}

/// MuMu is an Android backend, but its indices and lifecycle commands are not AVDs.
public struct MuMuProvider: DeviceProvider {
    public let platform = Platform.Android
    let config: Configuration
    let runner = ProcessRunner()
    private let catalogOverride: URL?
    private let managerLauncher: ((Device) async throws -> Void)?
    private let processList: (() async throws -> String)?
    public init(_ config: Configuration) { self.config = config; catalogOverride = nil; managerLauncher = nil; processList = nil }
    init(_ config: Configuration, catalogRoot: URL, managerLauncher: ((Device) async throws -> Void)? = nil, processList: (() async throws -> String)? = nil) {
        self.config = config; catalogOverride = catalogRoot; self.managerLauncher = managerLauncher; self.processList = processList
    }

    func catalogRoot() async throws -> URL {
        if let catalogOverride { return catalogOverride }
        let app = URL(fileURLWithPath: try await path()).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let identifier = Bundle(url: app)?.bundleIdentifier ?? "com.netease.mumu.nemux"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").appendingPathComponent(identifier)
    }

    func offlineDevices() async throws -> [Device] {
        let processes: String
        if let processList { processes = try await processList() }
        else { processes = try await runner.run("/bin/ps", ["-axww", "-o", "comm="], timeout: 5) }
        // If a guest survived the manager, do not label it stopped or allow a duplicate boot.
        let state: DeviceState = processes.contains("/MuMuEmulator.app/Contents/MacOS/MuMuEmulator") ? .unknown : .stopped
        return try MuMuCatalog.read(root: await catalogRoot(), state: state)
    }

    public func path() async throws -> String {
        if let manual = config.mumuTool, !manual.isEmpty {
            return try PathDiscovery.resolve(manual, candidates: [])
        }
        var apps = ["/Applications/MuMuPlayer.app", "~/Applications/MuMuPlayer.app", "/Applications/MuMuPlayer Pro.app"]
        if let common = try? PathDiscovery.resolve("", candidates: apps.map { $0 + "/Contents/MacOS/mumutool" } + PathDiscovery.pathCandidates("mumutool")) { return common }
        if let output = try? await runner.run("/usr/bin/mdfind", ["kMDItemFSName == '*MuMu*.app'cd"], timeout: 5) {
            apps += output.split(separator: "\n").map(String.init)
        }
        return try PathDiscovery.resolve("", candidates: apps.map { $0 + "/Contents/MacOS/mumutool" } + PathDiscovery.pathCandidates("mumutool"))
    }

    public func adb() async throws -> String {
        let macOS = URL(fileURLWithPath: try await path()).deletingLastPathComponent()
        return try PathDiscovery.resolve(config.adb, candidates: [macOS.appendingPathComponent("MuMuEmulator.app/Contents/MacOS/tools/adb").path] + PathDiscovery.sdkRoots.map { $0 + "/platform-tools/adb" } + PathDiscovery.pathCandidates("adb"))
    }

    /// MuMu sometimes returns exit status zero even for errors. Check the JSON envelope.
    static func serviceUnavailable(_ text: String) -> Bool {
        text.contains("invalidPort") || text.contains("URLSessionTask failed with error:")
    }
    public static func response(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["errcode"] as? Int else {
            if serviceUnavailable(text) { throw MuMuServiceUnavailable() }
            throw CLIError(L10n.text("Invalid MuMu response") + " " + String(text.prefix(500)))
        }
        guard code == 0 else { throw MuMuCommandError(code: code, message: root["message"] as? String ?? "") }
        return root
    }

    public static func rows(_ text: String) throws -> [[String: Any]] {
        let root = try response(text)
        guard let result = root["return"] as? [String: Any], let rows = result["results"] as? [[String: Any]] else {
            throw CLIError(L10n.text("Invalid MuMu response"))
        }
        return rows
    }

    // The AVD parser intentionally excludes TCP devices. MuMu uses exact loopback targets.
    public static func connectedTargets(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] == "device", fields[0].hasPrefix("127.0.0.1:") else { return nil }
            return String(fields[0])
        })
    }

    public static func parse(_ text: String) throws -> [Device] {
        var seen = Set<Int>()
        return try rows(text).map { row in
            guard let index = row["index"] as? Int, index >= 0, seen.insert(index).inserted,
                  let name = row["name"] as? String, let state = row["state"] as? String,
                  let directory = row["bundle_path"] as? String, directory.hasPrefix("/") else {
                throw CLIError(L10n.text("Invalid MuMu response"))
            }
            let status: DeviceState
            switch state.lowercased() {
            case "running": status = .running
            case "stopped": status = .stopped
            case "starting", "booting", "stopping": status = .starting
            default: status = .unknown
            }
            var device = Device(platform: .Android, key: String(index), name: name, state: status, detail: "MuMu · Android")
            device.backend = .mumu
            device.directory = directory
            device.instanceID = directory
            if let port = row["adb_port"] as? Int, (1...65535).contains(port) { device.serial = "127.0.0.1:\(port)" }
            return device
        }
    }

    public func listIfInstalled() async throws -> [Device] {
        guard (try? await path()) != nil else {
            if !(config.mumuTool ?? "").isEmpty { _ = try await path() }
            return []
        }
        return try await list()
    }

    public func rawList() async throws -> String {
        do {
            let output = try await runner.run(path(), ["info", "all"], timeout: 10)
            do { _ = try Self.response(output) }
            catch let error as MuMuCommandError where error.code == 42005 { throw MuMuServiceUnavailable() }
            return output
        }
        catch {
            if Self.serviceUnavailable(error.localizedDescription) { throw MuMuServiceUnavailable() }
            throw error
        }
    }

    public func list() async throws -> [Device] {
        var devices: [Device]
        do { devices = try Self.parse(await rawList()) }
        catch is MuMuServiceUnavailable { return try await offlineDevices() }
        // Live instances can publish an ADB port before Android accepts connections.
        // Retry missing connections on refresh without launching a guest or using disk-cached ports.
        if devices.contains(where: { $0.state == .running }), let adb = try? await adb(),
           let output = try? await runner.run(adb, ["devices"], timeout: 5) {
            let connected = Self.connectedTargets(output)
            for i in devices.indices where devices[i].state == .running {
                if let serial = devices[i].serial, !connected.contains(serial) {
                    guard let (fresh, _) = try? await connectedDevice(devices[i]) else { continue }
                    devices[i].serial = fresh.serial
                }
                guard let serial = devices[i].serial,
                      let properties = try? await runner.run(adb, ["-s", serial, "shell", "getprop"], timeout: 3) else { continue }
                let version = AndroidSystemInfo.fromProperties(AndroidSystemInfo.properties(properties)).detail
                if !version.isEmpty { devices[i].detail = "MuMu · " + version }
            }
        }
        return devices
    }

    private func execute(_ action: String, device: Device) async throws {
        // Revalidate identity: MuMu can reuse an index after a device has been deleted.
        var current: [Device]
        var launchedManager = false
        do { current = try Self.parse(await rawList()) }
        catch is MuMuServiceUnavailable {
            guard action == "open" else { throw MuMuServiceUnavailable() }
            let offline = try await offlineDevices().first { $0.id == device.id }
            guard let offline, offline.state == .stopped, device.backend == .mumu,
                  LogConnection.fingerprint(offline) == LogConnection.fingerprint(device) else {
                throw CLIError(L10n.text("Cannot confirm the selected device connection."))
            }
            if let managerLauncher { try await managerLauncher(offline) }
            else {
                let tool = try await path()
                _ = try await runner.run("/usr/bin/open", Self.managerOpenArguments(tool: tool, device: offline), timeout: 10)
            }
            launchedManager = true
            let deadline = Date().addingTimeInterval(20)
            while true {
                try Task.checkCancellation()
                do { current = try Self.parse(await rawList()); break }
                catch is MuMuServiceUnavailable {
                    guard Date() < deadline else { throw MuMuServiceUnavailable() }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        let fresh = current.first { $0.id == device.id }
        guard device.backend == .mumu, let fresh, LogConnection.fingerprint(fresh) == LogConnection.fingerprint(device) else {
            throw CLIError(L10n.text("Device identity changed. Reopen device information from the device list."))
        }
        // Opening the .mad document can itself start the selected guest.
        if action == "open" && launchedManager && [.running, .starting].contains(fresh.state) { return }
        if action == "open" { guard fresh.state == .stopped else { throw CLIError(L10n.text("设备状态已变化，请刷新后重试")) } }
        if action == "close" { guard fresh.state == .running else { throw CLIError(L10n.text("设备状态已变化，请刷新后重试")) } }
        if action == "delete" { try DeviceDeletion.validate(fresh) }
        let launchDeadline = Date().addingTimeInterval(15)
        while true {
            do {
                _ = try Self.response(await runner.run(path(), [action, fresh.key], timeout: 30))
                return
            } catch let error as MuMuCommandError where action == "open" && launchedManager && error.code == 42005 && Date() < launchDeadline {
                // The remote server can accept info before MuMu's launcher is ready.
                // Recheck before retrying: an earlier document/open request may have started it.
                let latest = try Self.parse(await rawList()).first { $0.id == fresh.id }
                guard let latest, LogConnection.fingerprint(latest) == LogConnection.fingerprint(device) else { throw error }
                if [.running, .starting].contains(latest.state) { return }
                guard latest.state == .stopped else { throw error }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    static func managerOpenArguments(tool: String, device: Device) -> [String] {
        let app = URL(fileURLWithPath: tool).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Pass the selected document on initial launch, rather than launching a default device.
        return ["-a", app.path, device.directory!]
    }
    public func start(_ device: Device, mode: BootMode) async throws {
        guard mode == .normal else { throw CLIError(L10n.text("MuMu cold boot unsupported")) }
        let adbPath = try await adb()
        _ = try await runner.run(adbPath, ["start-server"], timeout: 10)
        try await execute("open", device: device)
        // MuMu may initialize or replace its ADB service while opening the manager.
        _ = try await runner.run(adbPath, ["start-server"], timeout: 10)
        if let fresh = try? Self.parse(await rawList()).first(where: { $0.id == device.id }),
           fresh.state == .running, LogConnection.fingerprint(fresh) == LogConnection.fingerprint(device) {
            _ = try? await connectedDevice(fresh)
        }
        // If Android is still booting, list() will retry the live port on the next refresh.
    }
    public func stop(_ device: Device) async throws { try await execute("close", device: device) }
    public func delete(_ device: Device) async throws { try await execute("delete", device: device) }

    public func connectedDevice(_ device: Device, expectedIdentity: String? = nil) async throws -> (Device, String) {
        let current = try Self.parse(await rawList())
        guard let fresh = current.first(where: { $0.id == device.id }),
              LogConnection.fingerprint(fresh) == (expectedIdentity ?? LogConnection.fingerprint(device)), fresh.state == .running,
              let serial = fresh.serial else { throw CLIError(L10n.text("Cannot confirm the selected device connection.")) }
        let adb = try await adb()
        _ = try await runner.run(adb, ["connect", serial], timeout: 8)
        let targets = Self.connectedTargets(try await runner.run(adb, ["devices"], timeout: 5))
        guard targets.contains(serial) else { throw CLIError(L10n.text("MuMu ADB unavailable")) }
        let confirmed = try Self.parse(await rawList()).first { $0.id == fresh.id }
        guard let confirmed, confirmed.state == .running, confirmed.serial == serial,
              LogConnection.fingerprint(confirmed) == LogConnection.fingerprint(fresh) else {
            throw CLIError(L10n.text("Cannot confirm the selected device connection."))
        }
        return (fresh, adb)
    }
}
