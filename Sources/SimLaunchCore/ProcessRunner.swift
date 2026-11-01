import Foundation
import Darwin

public struct CLIError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Blocking Foundation work runs off the UI actor. Files avoid pipe-buffer deadlocks.
public struct ProcessRunner {
    public init() {}
    public func run(_ path: String, _ args: [String], environment: [String: String] = [:], timeout: TimeInterval = 20) async throws -> String {
        try await Task.detached {
            let process = Process()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close(); try? FileManager.default.removeItem(at: url) }
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            process.standardOutput = output; process.standardError = output
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning {
                process.terminate()
                try await Task.sleep(nanoseconds: 300_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw CLIError(L10n.format("Command timed out: %@ %@", URL(fileURLWithPath: path).lastPathComponent, args.joined(separator: " ")))
            }
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            guard process.terminationStatus == 0 else { throw CLIError(L10n.format("Exit code %d: %@", process.terminationStatus, String(text.prefix(3000)))) }
            return text
        }.value
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
