import Foundation
import Darwin

/// Some Emulator versions report `hw.hdc.port=notset` even while running.
/// Resolve only listening sockets owned by the exact selected emulator process.
enum HarmonyLogTarget {
    static func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 && argc < 4096 else { return nil }
        var index = 4
        while index < size && bytes[index] != 0 { index += 1 } // executable path
        while index < size && bytes[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            guard index < size else { return nil }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self)); index += 1
        }
        return result
    }
    static func matches(_ args: [String], executable: String, name: String, directory: String?) -> Bool {
        guard let first = args.first,
              URL(fileURLWithPath: first).resolvingSymlinksInPath().path == URL(fileURLWithPath: executable).resolvingSymlinksInPath().path else { return false }
        func value(_ flags: [String]) -> String? {
            for flag in flags { if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] } }
            return nil
        }
        guard value(["-start", "-hvd"]) == name else { return false }
        if let supplied = value(["-instancePath", "-path"]), let directory {
            return URL(fileURLWithPath: supplied).standardizedFileURL.path == URL(fileURLWithPath: directory).standardizedFileURL.path
        }
        return true
    }
    static func listeningTargets(_ output: String) -> [String] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("n") else { return nil }
            let address = String(line.dropFirst())
            guard address.hasPrefix("127.0.0.1:") || address.hasPrefix("[::1]:") else { return nil }
            return address
        }
    }
    static func targets(executable: String, name: String, directory: String?) async throws -> [String] {
        let runner = ProcessRunner()
        let pids = try await runner.run("/bin/ps", ["-axww", "-o", "pid=,comm="])
        let selectedPath = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        var result: [String] = []
        for line in pids.components(separatedBy: .newlines) {
            try Task.checkCancellation()
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2,
                  URL(fileURLWithPath: String(parts[1]).trimmingCharacters(in: .whitespaces)).resolvingSymlinksInPath().path == selectedPath,
                  let pid = Int32(parts[0]), let args = arguments(pid: pid),
                  matches(args, executable: executable, name: name, directory: directory) else { continue }
            let output = try await runner.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], timeout: 5)
            result += listeningTargets(output)
        }
        return result
    }
}
