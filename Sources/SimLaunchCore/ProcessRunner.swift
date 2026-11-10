import Foundation
import Darwin

public struct CLIError: LocalizedError {
    public let message: String
    let timedOut: Bool
    public var errorDescription: String? { message }
    public init(_ message: String) { self.init(message, timedOut: false) }
    init(_ message: String, timedOut: Bool) { self.message = message; self.timedOut = timedOut }
}

/// Blocking Foundation work runs off the UI actor. Files avoid pipe-buffer deadlocks.
public struct ProcessRunner {
    public init() {}
    public func run(_ path: String, _ args: [String], environment: [String: String] = [:], timeout: TimeInterval = 20) async throws -> String {
        String(decoding: try await runData(path, args, environment: environment, timeout: timeout), as: UTF8.self)
    }
    public func runData(_ path: String, _ args: [String], environment: [String: String] = [:], timeout: TimeInterval = 20) async throws -> Data {
        try await capture(path, args, environment: environment, timeout: timeout, destination: nil)
    }

    /// The destination belongs to the caller's staging directory. Keep diagnostics out of the file.
    func runToFile(_ path: String, _ args: [String], environment: [String: String], timeout: TimeInterval, destination: URL) async throws {
        _ = try await capture(path, args, environment: environment, timeout: timeout, destination: destination)
    }

    func runFromFile(_ path: String, _ args: [String], environment: [String: String], timeout: TimeInterval, source: URL) async throws -> String {
        String(decoding: try await capture(path, args, environment: environment, timeout: timeout, destination: nil, source: source), as: UTF8.self)
    }

    private func capture(_ path: String, _ args: [String], environment: [String: String], timeout: TimeInterval, destination: URL?, source: URL? = nil) async throws -> Data {
        let operation = Task.detached {
            let process = Process()
            defer {
                if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            }
            let diagnostics = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: diagnostics.path, contents: nil, attributes: [.posixPermissions: 0o600])
            defer { try? FileManager.default.removeItem(at: diagnostics) }
            let errorOutput = try FileHandle(forWritingTo: diagnostics)
            defer { try? errorOutput.close() }
            let output: FileHandle
            if let destination {
                FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
                output = try FileHandle(forWritingTo: destination)
            } else {
                output = errorOutput
            }
            defer { if destination != nil { try? output.close() } }
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            process.standardOutput = output; process.standardError = errorOutput
            let input = try source.map { try FileHandle(forReadingFrom: $0) }
            defer { try? input?.close() }
            process.standardInput = input ?? FileHandle.nullDevice
            try Task.checkCancellation()
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning {
                process.terminate()
                try await Task.sleep(nanoseconds: 300_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw CLIError(L10n.format("Command timed out: %@ %@", URL(fileURLWithPath: path).lastPathComponent, args.joined(separator: " ")), timedOut: true)
            }
            try Task.checkCancellation()
            if process.terminationStatus != 0 {
                let reader = try FileHandle(forReadingFrom: diagnostics)
                defer { try? reader.close() }
                let text = String(decoding: try reader.read(upToCount: 12_000) ?? Data(), as: UTF8.self)
                throw CLIError(L10n.format("Exit code %d: %@", process.terminationStatus, String(text.prefix(3000))))
            }
            return destination == nil ? try Data(contentsOf: diagnostics) : Data()
        }
        return try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
    }
}

/// Keep long-lived launchers alive; their output goes to a log, never an unread pipe.
public actor LaunchManager {
    private var processes: [String: Process] = [:]
    public init() {}
    public func launch(key: String, path: String, args: [String], environment: [String: String] = [:]) async throws {
        if processes[key]?.isRunning == true { throw CLIError(L10n.text("该设备正在启动")) }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SimLaunch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        p.standardOutput = handle; p.standardError = handle; p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] process in
            try? handle.close()
            Task { await self?.finished(key, process) }
        }
        try p.run(); processes[key] = p
        try await Task.sleep(nanoseconds: 700_000_000)
        if !p.isRunning && p.terminationStatus != 0 {
            let message = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw CLIError(L10n.format("Launch failed (exit %d): %@\nLog: %@", p.terminationStatus, String(message.suffix(2000)), log.path))
        }
    }
    private func finished(_ key: String, _ process: Process) {
        if processes[key] === process { processes.removeValue(forKey: key) }
    }
}
