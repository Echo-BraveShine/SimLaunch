import Foundation
import Darwin

public struct LogCommand: Sendable {
    public let path: String
    public let arguments: [String]
    public let environment: [String: String]
    public let target: String
    public init(path: String, arguments: [String], environment: [String: String] = [:], target: String) {
        self.path = path; self.arguments = arguments; self.environment = environment; self.target = target
    }
}
public enum LogStreamEvent: Sendable {
    case line(String, truncated: Bool)
    case diagnostic(String)
    case ended(Int32)
}

/// Each reader owns its process group, pipes and incremental decoders. No polling files,
/// unbounded asynchronous event queue, shell expansion, or global adb/hdc server termination.
public final class LogStreamProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.ekko.simlaunch.log-stream", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var pid: pid_t = 0
    private var outputFD: Int32 = -1
    private var errorFD: Int32 = -1
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var output = LogLineFramer()
    private var errors = LogLineFramer()
    private var callback: (@Sendable (LogStreamEvent) -> Void)?
    private var stopping = false

    public init() { queue.setSpecific(key: queueKey, value: true) }
    public func start(_ command: LogCommand, onEvent: @escaping @Sendable (LogStreamEvent) -> Void) throws {
        try queue.sync {
            guard pid == 0 else { throw CLIError("Log stream already active") }
            var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
            guard pipe(&out) == 0 else { throw POSIXError(.EMFILE) }
            guard pipe(&err) == 0 else { close(out[0]); close(out[1]); throw POSIXError(.EMFILE) }
            var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
            for fd in out + err { posix_spawn_file_actions_addclose(&actions, fd) }
            // Set a dedicated process group atomically at spawn time.
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            posix_spawnattr_setpgroup(&attributes, 0)
            let argv = ([command.path] + command.arguments).map { strdup($0) } + [nil]
            let env = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
            let envp = env.map { strdup($0.key + "=" + $0.value) } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var child: pid_t = 0
            let code = argv.withUnsafeBufferPointer { argv in envp.withUnsafeBufferPointer { envp in
                posix_spawn(&child, command.path, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            } }
            close(out[1]); close(err[1])
            guard code == 0 else { close(out[0]); close(err[0]); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            pid = child; stopping = false; output = LogLineFramer(); errors = LogLineFramer(); callback = onEvent
            outputFD = out[0]; errorFD = err[0]
            for fd in [outputFD, errorFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            outputSource = DispatchSource.makeReadSource(fileDescriptor: outputFD, queue: queue)
            errorSource = DispatchSource.makeReadSource(fileDescriptor: errorFD, queue: queue)
            outputSource?.setEventHandler { [weak self] in self?.readAvailable(stderr: false) }
            errorSource?.setEventHandler { [weak self] in self?.readAvailable(stderr: true) }
            exitSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
            exitSource?.setEventHandler { [weak self] in self?.finished(child) }
            outputSource?.resume(); errorSource?.resume(); exitSource?.resume()
        }
    }
    public var isRunning: Bool { queue.sync { pid != 0 } }
    public func stop() {
        queue.async { [self] in
            guard pid > 0, !stopping else { return }
            stopping = true
            let child = pid
            _ = kill(-child, SIGINT)
            queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.pid == child else { return }; _ = kill(-child, SIGTERM)
            }
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.pid == child else { return }; _ = kill(-child, SIGKILL)
            }
        }
    }
    /// Termination path for application exit; do not leave a reader or its children behind.
    public func stopImmediately() {
        if DispatchQueue.getSpecific(key: queueKey) == true { killAndReap() }
        else { queue.sync { killAndReap() } }
    }
    private func killAndReap() {
        if pid > 0 { let child = pid; _ = kill(-child, SIGKILL); var status: Int32 = 0; while waitpid(child, &status, 0) == -1 && errno == EINTR {} }
        cleanup(); callback = nil
    }
    private func readAvailable(stderr: Bool) {
        let fd = stderr ? errorFD : outputFD
        guard fd >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        var readBytes = 0
        while readBytes < 262_144 {
            let length = read(fd, &bytes, bytes.count)
            if length > 0 {
                readBytes += length
                let data = Data(bytes.prefix(length))
                let lines = stderr ? errors.consume(data) : output.consume(data)
                emit(lines, stderr: stderr)
            } else if length == -1 && errno == EINTR { continue }
            else {
                if length == 0 {
                    emit(stderr ? errors.finish() : output.finish(), stderr: stderr)
                    if stderr { errorSource?.cancel(); errorSource = nil; close(errorFD); errorFD = -1 }
                    else { outputSource?.cancel(); outputSource = nil; close(outputFD); outputFD = -1 }
                }
                break
            }
        }
    }
    private func emit(_ lines: [(String, Bool)], stderr: Bool) {
        for (line, clipped) in lines {
            if stderr { callback?(.diagnostic(line)) }
            else { callback?(.line(line, truncated: clipped)) }
        }
    }
    private func finished(_ child: pid_t) {
        guard pid == child else { return }
        readAvailable(stderr: false); readAvailable(stderr: true)
        emit(output.finish(), stderr: false); emit(errors.finish(), stderr: true)
        // The group is still ours while its leader is unreaped. A CLI may exit
        // before a helper, so clean descendants even after a normal leader exit.
        _ = kill(-child, SIGKILL)
        var status: Int32 = 0
        let waited = waitpid(child, &status, 0)
        let code: Int32 = waited > 0 ? (status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)) : -1
        let notify = callback; cleanup(); callback = nil; notify?(.ended(code))
    }
    private func cleanup() {
        outputSource?.cancel(); errorSource?.cancel(); exitSource?.cancel()
        outputSource = nil; errorSource = nil; exitSource = nil
        if outputFD >= 0 { close(outputFD) }; if errorFD >= 0 { close(errorFD) }
        outputFD = -1; errorFD = -1; pid = 0
    }
    deinit { stopImmediately() }
}
