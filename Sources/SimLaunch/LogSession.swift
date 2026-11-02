import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import SimLaunchCore

private final class LogInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = DeviceLogBuffer()
    private var revision: UInt64 = 0
    private var diagnostic = ""
    private var exit: Int32?
    private let platform: Platform
    init(platform: Platform) { self.platform = platform }
    func receive(_ event: LogStreamEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case let .line(text, clipped): buffer.append(text, platform: platform, truncated: clipped)
        case let .diagnostic(text): diagnostic = String(text.prefix(4000))
        case let .ended(code): exit = code
        }
        revision &+= 1
    }
    func marker(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        buffer.append("── " + text + " ──", platform: platform, marker: true); revision &+= 1
    }
    func newConnection() { lock.lock(); defer { lock.unlock() }; exit = nil; diagnostic = ""; revision &+= 1 }
    func clear() { lock.lock(); defer { lock.unlock() }; buffer.clear(); revision &+= 1 }
    func snapshot(after previous: UInt64) -> (UInt64, [DeviceLogEntry], Int, Int, String, Int32?)? {
        lock.lock(); defer { lock.unlock() }
        guard revision != previous else { return nil }
        return (revision, buffer.entries, buffer.dropped, buffer.truncated, diagnostic, exit)
    }
}

enum LogCaptureState: String {
    case waiting, connecting, capturing, stopping, disconnected, stopped
    var title: String { L10n.text("Log status " + rawValue) }
    var actionTitle: String {
        switch self {
        case .connecting: return L10n.text("Cancel connection")
        case .stopping: return L10n.text("Log status stopping")
        case .capturing: return L10n.text("Stop collection")
        default: return L10n.text("Start collection")
        }
    }
    var active: Bool { self == .connecting || self == .capturing || self == .stopping }
}

@MainActor final class LogSession: ObservableObject {
    let device: Device
    let identity: String
    @Published private(set) var entries: [DeviceLogEntry] = []
    @Published private(set) var visible: [DeviceLogEntry] = []
    @Published private(set) var state = LogCaptureState.waiting
    @Published private(set) var diagnostic = ""
    @Published private(set) var deviceReady = false
    @Published private(set) var dropped = 0
    @Published private(set) var truncated = 0
    @Published var filter = DeviceLogFilter() { didSet { updateFiltered() } }
    @Published var follow = true
    @Published var wrap = false
    @Published private(set) var clearRevision: UInt64 = 0
    @Published var exportError: String?
    private(set) var target = "—"
    private(set) var started: Date?
    private var reader: LogStreamProcess?
    private var connectionTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var generation = UUID()
    private var revision: UInt64 = 0
    private var inbox: LogInbox
    private var released = true
    private var closed = false
    private var subscriptions = Set<AnyCancellable>()
    private weak var owner: LogWindowManager?
    private weak var store: Store?

    init(device: Device, store: Store, owner: LogWindowManager) {
        self.device = device; self.store = store; self.owner = owner
        identity = LogConnection.fingerprint(device); inbox = LogInbox(platform: device.platform)
        deviceReady = device.state == .running
        store.$devices.sink { [weak self] current in
            guard let self, store.hasRefreshed else { return }
            self.checkDevice(current)
        }.store(in: &subscriptions)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 350_000_000) } catch { break }
                self?.flush()
            }
        }
    }
    func start() {
        guard !closed, !state.active, let store, let owner else { return }
        diagnostic = ""
        guard let current = store.devices.first(where: { $0.id == device.id }), current.state == .running else {
            state = .waiting; diagnostic = L10n.text("Start the simulator and wait until it is connected before collecting logs."); return
        }
        guard LogConnection.fingerprint(current) == identity else {
            state = .disconnected; diagnostic = L10n.text("The device was removed or recreated. Open a new log window from the device list."); return
        }
        guard owner.acquire(device.id) else { diagnostic = L10n.text("Up to three devices can collect logs at once. Stop another session first."); return }
        released = false; state = .connecting
        let token = UUID(); generation = token
        let config = store.config
        connectionTask = Task { [weak self] in
            do {
                let command = try await LogConnection.command(device: current, configuration: config, expectedIdentity: self?.identity)
                try Task.checkCancellation()
                guard let self, !self.closed, self.generation == token else { return }
                self.target = command.target; self.inbox.newConnection()
                let now = Date(); self.started = now
                self.inbox.marker(L10n.format("Capture started: %@", now.formatted(date: .numeric, time: .standard)))
                self.inbox.marker(L10n.text("Source timestamps are preserved. Earlier buffered logs may appear."))
                let inbox = self.inbox
                let process = LogStreamProcess()
                // Starting a process is short; pipe work and parsing stay off the UI thread.
                self.reader = process
                try process.start(command) { event in inbox.receive(event) }
                self.state = .capturing; self.flush()
            } catch {
                guard let self, self.generation == token, !self.closed else { return }
                self.state = .disconnected; self.diagnostic = error.localizedDescription
                self.reader = nil; self.releaseSlot()
            }
        }
    }
    func stop() { endCapture(disconnected: false) }
    private func endCapture(disconnected: Bool) {
        guard state.active else { return }
        generation = UUID(); connectionTask?.cancel(); connectionTask = nil
        if let reader, reader.isRunning {
            state = disconnected ? .disconnected : .stopping
            reader.stop()
        } else { state = disconnected ? .disconnected : .stopped; releaseSlot() }
    }
    private func checkDevice(_ devices: [Device]) {
        deviceReady = devices.contains { $0.id == device.id && $0.state == .running && LogConnection.fingerprint($0) == identity }
        guard state == .connecting || state == .capturing else { return }
        guard let current = devices.first(where: { $0.id == device.id }), current.state == .running, LogConnection.fingerprint(current) == identity else {
            diagnostic = L10n.text("The device is disconnected or its identity changed. Reconnect after checking the device list.")
            endCapture(disconnected: true); return
        }
    }
    func flush() {
        guard let snapshot = inbox.snapshot(after: revision) else { return }
        revision = snapshot.0; entries = snapshot.1; dropped = snapshot.2; truncated = snapshot.3
        if !snapshot.4.isEmpty { diagnostic = snapshot.4 }
        updateFiltered()
        if let code = snapshot.5, !released {
            if state == .stopping { state = .stopped }
            else {
                state = .disconnected
                if diagnostic.isEmpty { diagnostic = L10n.format("Log connection ended (exit %d).", code) }
            }
            reader = nil; releaseSlot()
        }
    }
    private func updateFiltered() { visible = entries.filter(filter.matches) }
    func clear() { clearRevision &+= 1; inbox.clear(); flush() }
    func resetFilter() { filter = DeviceLogFilter() }
    func copyDisplayed(_ snapshot: [DeviceLogEntry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.map(\.raw).joined(separator: "\n"), forType: .string)
    }
    func export(displayed snapshot: [DeviceLogEntry]? = nil, filter snapshotFilter: DeviceLogFilter? = nil) {
        flush()
        let text = DeviceLogExport.text(deviceName: device.name, platform: device.platform, target: target, started: started,
                                       entries: snapshot ?? entries, filter: snapshotFilter, dropped: dropped, truncated: truncated)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText, .plainText]
        panel.nameFieldStringValue = "SimLaunch-" + device.platform.rawValue + "-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".log"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { [weak self] in
                do { try await Task.detached(priority: .utility) { try text.write(to: url, atomically: true, encoding: .utf8) }.value }
                catch { self?.exportError = error.localizedDescription }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    func close() {
        guard !closed else { return }
        closed = true; generation = UUID(); connectionTask?.cancel(); timerTask?.cancel(); subscriptions.removeAll()
        if let reader {
            reader.stop()
            owner?.retire(reader, key: device.id)
            self.reader = nil
        } else { releaseSlot() }
    }
    private func releaseSlot() { if !released { owner?.release(device.id); released = true } }
    deinit { connectionTask?.cancel(); timerTask?.cancel() }
}

@MainActor final class LogWindowManager {
    private let store: Store
    private var windows: [String: LogWindowController] = [:]
    private var active: Set<String> = []
    private var retired: [UUID: LogStreamProcess] = [:]
    init(store: Store) { self.store = store }
    func acquire(_ key: String) -> Bool {
        guard !active.contains(key), active.count < 3 else { return false }; active.insert(key); return true
    }
    func release(_ key: String) { active.remove(key) }
    func retire(_ reader: LogStreamProcess, key: String) {
        let token = UUID(); retired[token] = reader
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            reader.stopImmediately(); self?.retired.removeValue(forKey: token); self?.release(key)
        }
    }
    func show(_ device: Device) {
        if let existing = windows[device.id] { existing.reveal(); return }
        let session = LogSession(device: device, store: store, owner: self)
        let controller = LogWindowController(session: session) { [weak self] in self?.windows.removeValue(forKey: device.id) }
        windows[device.id] = controller
        controller.reveal(); session.start()
    }
    func refreshAppearanceAndTitles() { for window in windows.values { window.updateAppearanceAndTitle() } }
    func shutdown(_ completion: @escaping () -> Void) -> Bool {
        guard !windows.isEmpty || !retired.isEmpty else { return false }
        for window in windows.values { window.session.close() }
        Task { [self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            for reader in retired.values { reader.stopImmediately() }
            retired.removeAll(); active.removeAll(); completion()
        }
        return true
    }
}

@MainActor private final class LogWindowController: NSWindowController, NSWindowDelegate {
    let session: LogSession
    private let onClose: () -> Void
    init(session: LogSession, onClose: @escaping () -> Void) {
        self.session = session; self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: DeviceLogView(session: session))
        window.contentMinSize = NSSize(width: 800, height: 540)
        window.setContentSize(NSSize(width: 1050, height: 700))
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.initialFirstResponder = nil
        window.delegate = self; window.center(); updateAppearanceAndTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reveal() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil); window?.orderFrontRegardless(); window?.makeFirstResponder(nil)
    }
    func updateAppearanceAndTitle() {
        window?.title = L10n.format("Live logs — %@", session.device.name)
        window?.appearance = nil // Inherit live app appearance, including title-bar changes.
    }
    func windowWillClose(_ notification: Notification) { session.close(); onClose() }
}
