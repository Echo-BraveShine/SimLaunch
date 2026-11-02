import Foundation

public enum LogLevel: String, CaseIterable, Sendable {
    case debug, info, warning, error, fault, other
    public var title: String { L10n.text("Log level " + rawValue) }
    static func parse(_ value: String) -> Self {
        switch value.lowercased() {
        case "v", "verbose", "d", "debug", "db": return .debug
        case "i", "info", "a", "activity": return .info
        case "w", "warn", "warning": return .warning
        case "e", "error": return .error
        case "f", "fatal", "fault": return .fault
        default: return .other
        }
    }
}

public struct DeviceLogEntry: Identifiable, Sendable {
    public let id: UInt64
    public let received: Date
    public let raw: String
    public let time: String?
    public let originalLevel: String?
    public let level: LogLevel
    public let pid: String?
    public let process: String?
    public let tag: String?
    public let isMarker: Bool
    public let truncated: Bool
    public var byteCount: Int { raw.utf8.count }
}

public enum DeviceLogParser {
    // Unknown formats are retained verbatim, never silently discarded.
    private static let android = try! NSRegularExpression(pattern: #"^\s*(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+)\s+(\d+)\s+\d+\s+([VDIWEFAS])\s+([^:]+):"#)
    private static let harmony = try! NSRegularExpression(pattern: #"^\s*(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+)\s+(\d+)\s+\d+\s+([VDIWEF])\s+([^:]+):"#)
    private static let ios = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[+-]\d+)?)\s+(\S+)\s+(.+?)\[(\d+):[^\]]+\]:?\s*(?:\[([^\]]+)\])?"#)
    public static func parse(_ raw: String, platform: Platform, id: UInt64, marker: Bool = false, truncated: Bool = false) -> DeviceLogEntry {
        var time: String?, original: String?, pid: String?, process: String?, tag: String?
        let regex = platform == .iOS ? ios : platform == .Android ? android : harmony
        if !marker, let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            func part(_ index: Int) -> String? {
                guard let r = Range(match.range(at: index), in: raw) else { return nil }
                return String(raw[r]).trimmingCharacters(in: .whitespaces)
            }
            time = part(1)
            if platform == .iOS { original = part(2); process = part(3); pid = part(4); tag = part(5) }
            else { pid = part(2); original = part(3); tag = part(4) }
        }
        return DeviceLogEntry(id: id, received: Date(), raw: raw, time: time, originalLevel: original,
                              level: original.map(LogLevel.parse) ?? .other, pid: pid, process: process, tag: tag, isMarker: marker, truncated: truncated)
    }
}

public struct DeviceLogFilter: Equatable, Sendable {
    public var keyword = ""
    public var ignoreCase = true
    public var levels = Set(LogLevel.allCases)
    public var pid = ""
    public var process = ""
    public init() {}
    public func matches(_ entry: DeviceLogEntry) -> Bool {
        if entry.isMarker { return true }
        guard levels.contains(entry.level) else { return false }
        if !pid.isEmpty && entry.pid != pid { return false }
        if !process.isEmpty && !(entry.process?.localizedCaseInsensitiveContains(process) ?? false) { return false }
        return keyword.isEmpty || entry.raw.range(of: keyword, options: ignoreCase ? [.caseInsensitive] : []) != nil
    }
    public var summary: String {
        "keyword=\(keyword); ignoreCase=\(ignoreCase); levels=\(levels.map(\.rawValue).sorted().joined(separator: ",")); pid=\(pid); process=\(process)"
    }
}

public struct DeviceLogBuffer {
    public static let maximumLines = 10_000
    public static let maximumBytes = 10 * 1024 * 1024
    private var storage: [DeviceLogEntry] = []
    private var head = 0
    private var nextID: UInt64 = 0
    public private(set) var bytes = 0
    public private(set) var dropped = 0
    public private(set) var truncated = 0
    private let lineLimit: Int
    private let byteLimit: Int
    public var entries: [DeviceLogEntry] { Array(storage[head...]) }
    public init(lineLimit: Int = maximumLines, byteLimit: Int = maximumBytes) {
        self.lineLimit = max(1, lineLimit); self.byteLimit = max(1, byteLimit)
    }
    public mutating func append(_ text: String, platform: Platform, marker: Bool = false, truncated: Bool = false) {
        nextID += 1
        let entry = DeviceLogParser.parse(text, platform: platform, id: nextID, marker: marker, truncated: truncated)
        storage.append(entry); bytes += entry.byteCount
        if truncated { self.truncated += 1 }
        while storage.count - head > lineLimit || bytes > byteLimit {
            bytes -= storage[head].byteCount; head += 1; dropped += 1
        }
        if head > 1024 && head * 2 > storage.count { storage.removeFirst(head); head = 0 }
    }
    public mutating func clear() { storage.removeAll(keepingCapacity: false); head = 0; bytes = 0; dropped = 0; truncated = 0 }
}

/// Frame bytes before decoding UTF-8, so chunk boundaries cannot corrupt Chinese or emoji.
public struct LogLineFramer {
    public static let maximumLineBytes = 64 * 1024
    private var pending = Data()
    private var clipped = false
    public init() {}
    public mutating func consume(_ data: Data) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 10 {
            append(data[start..<index]); result.append(take()); start = data.index(after: index)
        }
        append(data[start...]); return result
    }
    public mutating func finish() -> [(String, Bool)] { pending.isEmpty && !clipped ? [] : [take()] }
    private mutating func append(_ data: Data.SubSequence) {
        let remaining = max(0, Self.maximumLineBytes - pending.count)
        pending.append(contentsOf: data.prefix(remaining))
        if data.count > remaining { clipped = true }
    }
    private mutating func take() -> (String, Bool) {
        var bytes = pending
        if bytes.last == 13 { bytes.removeLast() }
        if clipped {
            // The byte limit can land in the middle of a UTF-8 scalar.
            for _ in 0..<3 where String(data: bytes, encoding: .utf8) == nil && !bytes.isEmpty { bytes.removeLast() }
        }
        var text = String(decoding: bytes, as: UTF8.self)
        if clipped { text += " … [truncated at 64 KiB]" }
        let wasClipped = clipped; pending.removeAll(keepingCapacity: true); clipped = false
        return (text, wasClipped)
    }
}

public enum DeviceLogExport {
    public static func text(deviceName: String, platform: Platform, target: String, started: Date?, entries: [DeviceLogEntry], filter: DeviceLogFilter?, dropped: Int, truncated: Int) -> String {
        let date = ISO8601DateFormatter()
        let header = ["SimLaunch device log", "Device: \(deviceName)", "Platform: \(platform.rawValue)", "Source: \(platform == .iOS ? "simctl log stream" : platform == .Android ? "adb logcat" : "hdc hilog")", "Target: \(target)",
                      "Capture started: \(started.map(date.string) ?? "—")", "Exported: \(date.string(from: Date()))",
                      "Filter: \(filter?.summary ?? "all retained lines")", "Discarded earlier lines: \(dropped)", "Truncated lines: \(truncated)", ""]
        return header.joined(separator: "\n") + "\n" + entries.map(\.raw).joined(separator: "\n") + "\n"
    }
}
