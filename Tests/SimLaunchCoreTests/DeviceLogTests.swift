import XCTest
@testable import SimLaunchCore
import Darwin

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [LogStreamEvent] = []
    private var hasNotified = false
    func firstNotification() -> Bool { lock.lock(); defer { lock.unlock() }; let first = !hasNotified; hasNotified = true; return first }
    func append(_ value: LogStreamEvent) { lock.lock(); contents.append(value); lock.unlock() }
    var events: [LogStreamEvent] { lock.lock(); defer { lock.unlock() }; return contents }
    var lines: [String] { events.compactMap { if case let .line(text, _) = $0 { return text }; return nil } }
}

final class DeviceLogTests: XCTestCase {
    func testFramingPreservesSplitUnicodeCRLFAndLastPartialLine() {
        let text = "中文🙂\r\nsecond\nend"
        let bytes = Data(text.utf8)
        var framer = LogLineFramer(), lines: [String] = []
        for byte in bytes { lines += framer.consume(Data([byte])).map { $0.0 } }
        lines += framer.finish().map { $0.0 }
        XCTAssertEqual(lines, ["中文🙂", "second", "end"])
        XCTAssertTrue(framer.finish().isEmpty)
    }
    func testOversizeLineBoundedAndRecoversAtNextNewline() {
        var framer = LogLineFramer()
        let data = Data((String(repeating: "中", count: 100_000) + "\nok\n").utf8)
        let lines = framer.consume(data)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].1)
        XCTAssertLessThan(lines[0].0.utf8.count, LogLineFramer.maximumLineBytes + 100)
        XCTAssertFalse(lines[0].0.contains("�"))
        XCTAssertEqual(lines[1].0, "ok"); XCTAssertFalse(lines[1].1)
    }
    func testPlatformParsersAndUnknownInputRemainIntact() {
        let android = DeviceLogParser.parse("11-02 12:30:40.123  123 456 E Example: 中文", platform: .Android, id: 1)
        XCTAssertEqual(android.pid, "123"); XCTAssertEqual(android.tag, "Example"); XCTAssertEqual(android.level, .error)
        let harmony = DeviceLogParser.parse("11-02 12:30:40.123  123 456 W A03200/testTag: message", platform: .HarmonyOS, id: 2)
        XCTAssertEqual(harmony.tag, "A03200/testTag"); XCTAssertEqual(harmony.level, .warning)
        let ios = DeviceLogParser.parse("2026-11-02 12:30:40.123 Df Example[123:456] [com.example:network] message", platform: .iOS, id: 3)
        XCTAssertEqual(ios.pid, "123"); XCTAssertEqual(ios.process, "Example"); XCTAssertEqual(ios.tag, "com.example:network")
        let unknown = DeviceLogParser.parse("  at some.stacktrace(Line:12)", platform: .Android, id: 4)
        XCTAssertNil(unknown.pid); XCTAssertEqual(unknown.level, .other)
        XCTAssertEqual(unknown.raw, "  at some.stacktrace(Line:12)")
    }
    func testRingLimitsClearAndMonotonicIDs() {
        var buffer = DeviceLogBuffer(lineLimit: 3, byteLimit: 12)
        for i in 0..<10 { buffer.append("row\(i)", platform: .Android) }
        XCTAssertEqual(buffer.entries.map(\.raw), ["row7", "row8", "row9"])
        XCTAssertEqual(buffer.dropped, 7); XCTAssertEqual(buffer.bytes, 12)
        let last = buffer.entries.last!.id
        buffer.clear(); XCTAssertTrue(buffer.entries.isEmpty); XCTAssertEqual(buffer.dropped, 0)
        buffer.append("next", platform: .Android, truncated: true)
        XCTAssertGreaterThan(buffer.entries.first!.id, last); XCTAssertEqual(buffer.truncated, 1)
        buffer.append(String(repeating: "x", count: 30), platform: .Android)
        XCTAssertLessThanOrEqual(buffer.bytes, 12)
    }
    func testFiltersCombineWithoutChangingRawCache() {
        let line = DeviceLogParser.parse("11-02 12:30:40.123 123 456 E Example: Hello", platform: .Android, id: 1)
        var filter = DeviceLogFilter()
        filter.keyword = "hello"; filter.pid = "123"; filter.levels = [.error]
        XCTAssertTrue(filter.matches(line))
        filter.ignoreCase = false; XCTAssertFalse(filter.matches(line))
        filter.keyword = "Hello"; XCTAssertTrue(filter.matches(line))
        filter.pid = "456"; XCTAssertFalse(filter.matches(line))
        filter.pid = "123"; filter.process = "Example"; XCTAssertFalse(filter.matches(line), "A tag is not a process name")
    }
    func testHDCRequiresUnambiguousEmulatorIdentity() throws {
        let row: [String: Any] = ["uuid": "some-emulator", "hw.hdc.port": "5555"]
        XCTAssertEqual(try LogConnection.harmonyTarget(row: row, connected: ["physical-phone", "127.0.0.1:5555"]), "127.0.0.1:5555")
        XCTAssertThrowsError(try LogConnection.harmonyTarget(row: row, connected: ["physical-phone"]))
        XCTAssertThrowsError(try LogConnection.harmonyTarget(row: row, connected: ["127.0.0.1:5555", "some-emulator"]))
        XCTAssertThrowsError(try LogConnection.harmonyTarget(row: ["hw.hdc.port": "notset"], connected: ["one-device"]))
    }
    func testHarmonyRuntimeAssociationUsesExactArgumentsAndLoopbackListeners() {
        let path = "/Applications/DevEco Studio.app/Contents/tools/emulator/Emulator"
        let args = [path, "-start", "My Phone", "-instancePath", "/tmp/My Phone"]
        XCTAssertTrue(HarmonyLogTarget.matches(args, executable: path, name: "My Phone", directory: "/tmp/My Phone"))
        XCTAssertFalse(HarmonyLogTarget.matches(args, executable: path, name: "My", directory: nil))
        XCTAssertFalse(HarmonyLogTarget.matches(args, executable: path, name: "My Phone", directory: "/tmp/Another"))
        XCTAssertFalse(HarmonyLogTarget.matches(["/tmp/Emulator", "-start", "My Phone"], executable: path, name: "My Phone", directory: nil))
        XCTAssertEqual(HarmonyLogTarget.listeningTargets("p123\nn127.0.0.1:5557\nn*:5555\nn[::1]:5559\n"), ["127.0.0.1:5557", "[::1]:5559"])
        XCTAssertEqual(try LogConnection.harmonyTarget(row: ["hw.hdc.port": "notset"], connected: ["physical", "127.0.0.1:5557"], runtimeTargets: ["127.0.0.1:5557"]), "127.0.0.1:5557")
    }
    func testFailedSpawnClosesResourcesAndAllowsRetry() async throws {
        let stream = LogStreamProcess()
        XCTAssertThrowsError(try stream.start(.init(path: "/does-not-exist/SimLaunchTest", arguments: [], target: "invalid")) { _ in })
        XCTAssertFalse(stream.isRunning)
        let ended = expectation(description: "retry ends")
        try stream.start(.init(path: "/usr/bin/true", arguments: [], target: "retry")) { event in if case .ended = event { ended.fulfill() } }
        await fulfillment(of: [ended], timeout: 3)
        XCTAssertFalse(stream.isRunning)
    }
    func testExportsFixedRetainedSnapshotWithLossMetadata() {
        var buffer = DeviceLogBuffer(lineLimit: 2)
        for i in 0..<3 { buffer.append("line\(i)", platform: .iOS) }
        let snapshot = buffer.entries
        let text = DeviceLogExport.text(deviceName: "A Device", platform: .iOS, target: "udid", started: nil, entries: snapshot, filter: nil, dropped: buffer.dropped, truncated: 2)
        buffer.clear()
        XCTAssertTrue(text.contains("Discarded earlier lines: 1")); XCTAssertTrue(text.contains("Truncated lines: 2"))
        XCTAssertTrue(text.contains("line1\nline2\n")); XCTAssertFalse(text.contains("line0"))
    }
    func testStreamDeliversBeforeExitAndSeparatesDiagnostics() async throws {
        let process = LogStreamProcess(), events = EventCollector()
        let gotLine = expectation(description: "first output while process remains alive")
        let ended = expectation(description: "drains tail and exits")
        try process.start(.init(path: "/bin/sh", arguments: ["-c", "printf '中文\\n'; printf 'diagnostic\\n' >&2; sleep 0.4; printf 'tail'"], target: "fixture")) { event in
            events.append(event)
            if case let .line(text, _) = event, text == "中文" { gotLine.fulfill() }
            if case .ended = event { ended.fulfill() }
        }
        await fulfillment(of: [gotLine], timeout: 3)
        XCTAssertTrue(process.isRunning)
        await fulfillment(of: [ended], timeout: 4)
        XCTAssertEqual(events.lines, ["中文", "tail"])
        XCTAssertTrue(events.events.contains { if case .diagnostic("diagnostic") = $0 { return true }; return false })
        XCTAssertFalse(process.isRunning)
    }
    func testFloodedStreamIsBoundedAndCanStop() async throws {
        let process = LogStreamProcess()
        let ready = expectation(description: "flood begins")
        let ended = expectation(description: "stop completes")
        let collector = EventCollector()
        try process.start(.init(path: "/usr/bin/awk", arguments: ["BEGIN { while(1) print \"abcdefghijklmnopqrstuvwxyz\" }"], target: "flood")) { event in
            if case .line = event {
                if collector.firstNotification() { ready.fulfill() }
            }
            if case .ended = event { ended.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 3)
        process.stop()
        await fulfillment(of: [ended], timeout: 4)
        XCTAssertFalse(process.isRunning)
    }
    func testStopEscalatesAndOwnedDescendantsAreTerminated() async throws {
        let process = LogStreamProcess(), events = EventCollector()
        let ready = expectation(description: "child pid")
        let ended = expectation(description: "terminated")
        try process.start(.init(path: "/bin/sh", arguments: ["-c", "trap '' INT TERM; sleep 30 & echo $!; wait"], target: "fixture")) { event in
            events.append(event)
            if case .line = event { ready.fulfill() }
            if case .ended = event { ended.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 3)
        let child = try XCTUnwrap(events.lines.first.flatMap(Int32.init))
        process.stop()
        await fulfillment(of: [ended], timeout: 5)
        // A killed descendant can briefly remain a zombie until launchd reaps it.
        XCTAssertFalse(process.isRunning)
        let probe = Process(); probe.executableURL = URL(fileURLWithPath: "/bin/ps"); probe.arguments = ["-o", "stat=", "-p", String(child)]
        let pipe = Pipe(); probe.standardOutput = pipe; probe.standardError = FileHandle.nullDevice
        try probe.run(); probe.waitUntilExit()
        let state = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(state.isEmpty || state.hasPrefix("Z"), "owned child must not keep running: \(state)")
    }
    func testLeaderExitAlsoCleansOwnedHelper() async throws {
        let stream = LogStreamProcess(), events = EventCollector()
        let ended = expectation(description: "leader exits")
        try stream.start(.init(path: "/bin/sh", arguments: ["-c", "sleep 30 & echo $!"], target: "fixture")) { event in
            events.append(event)
            if case .ended = event { ended.fulfill() }
        }
        await fulfillment(of: [ended], timeout: 4)
        let child = try XCTUnwrap(events.lines.first.flatMap(Int32.init))
        let state = (try? await ProcessRunner().run("/bin/ps", ["-o", "stat=", "-p", String(child)]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertTrue(state.isEmpty || state.hasPrefix("Z"), "Helper must not outlive its reader: \(state)")
    }
    func testCancellingPreflightRunnerStopsCommandPromptly() async throws {
        let task = Task { try await ProcessRunner().run("/bin/sleep", ["30"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation expected") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}

final class LiveDeviceLogTests: XCTestCase {
    func testSelectedRunningDevices() async throws {
        guard ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_LOG_STREAMS"] == "1" else {
            throw XCTSkip("Opt in with SIMLAUNCH_TEST_LOG_STREAMS=1 and running simulators")
        }
        let config = Configuration()
        let providers: [any DeviceProvider] = [IOSProvider(config), AndroidProvider(config, launches: LaunchManager()), HarmonyProvider(config, launches: LaunchManager())]
        for provider in providers {
            if let selected = ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_LOG_PLATFORM"], selected != provider.platform.rawValue { continue }
            let devices = try await provider.list()
            let device = try XCTUnwrap(devices.first { $0.state == .running }, "A running device is required: \(provider.platform); states=\(devices.map { $0.name + ":" + $0.state.rawValue }.joined(separator: ","))")
            let command = try await LogConnection.command(device: device, configuration: config)
            let stream = LogStreamProcess(), events = EventCollector()
            let first = expectation(description: "live output \(device.platform)")
            let ended = expectation(description: "stopped \(device.platform)")
            try stream.start(command) { event in
                events.append(event)
                if case .line = event, events.firstNotification() { first.fulfill() }
                if case .ended = event { ended.fulfill() }
            }
            defer { stream.stopImmediately() }
            await fulfillment(of: [first], timeout: 20)
            try await Task.sleep(nanoseconds: 500_000_000)
            stream.stop()
            await fulfillment(of: [ended], timeout: 5)
            let parsed = events.lines.map { DeviceLogParser.parse($0, platform: device.platform, id: 1) }
            XCTAssertTrue(parsed.contains { $0.pid != nil }, "Must parse the actual platform output")
            XCTAssertFalse(stream.isRunning)
            print("Live log verified: \(device.platform), target=\(command.target), lines=\(parsed.count), parsedPID=\(parsed.filter { $0.pid != nil }.count)")
        }
    }
}
