import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SimLaunchCore

@MainActor final class DeviceInformationSession: ObservableObject {
    let device: Device
    private let identity: String
    private weak var store: Store?
    @Published private(set) var information: DeviceInformation?
    @Published private(set) var loading = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    init(device: Device, store: Store) { self.device = device; self.store = store; identity = LogConnection.fingerprint(device) }
    func refresh() {
        guard !loading, let store else { return }
        loading = true
        let config = store.config, device = device, identity = identity
        task = Task { [weak self] in
            let result = await DeviceInformationReader.read(device: device, configuration: config, expectedIdentity: identity)
            guard !Task.isCancelled, let self else { return }
            self.information = result; self.loading = false
        }
    }
    func close() { task?.cancel(); task = nil; loading = false }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    func export() {
        guard let text = information?.report() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "SimLaunch-Device-Information.txt"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { [weak self] in
                do { try await Task.detached { try text.write(to: url, atomically: true, encoding: .utf8) }.value }
                catch { self?.error = error.localizedDescription }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
    deinit { task?.cancel() }
}

struct DeviceInformationView: View {
    @ObservedObject var session: DeviceInformationSession
    @AppStorage("appLanguage") private var language = "system"
    @State private var search = ""
    @State private var showRaw = false
    private func matches(_ field: DeviceInformationField) -> Bool {
        search.isEmpty || L10n.text(field.id).localizedCaseInsensitiveContains(search) || field.id.localizedCaseInsensitiveContains(search) || field.value.localizedCaseInsensitiveContains(search)
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                PlatformIcon(platform: session.device.platform, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.device.name).font(.title3.weight(.semibold))
                    Text(session.device.platform.rawValue + " · " + (session.information?.sections.first?.fields.first { $0.id == "Device state" }?.value ?? L10n.text(session.device.state.rawValue))).font(.caption).foregroundStyle(.secondary)
                    if !session.device.detail.isEmpty { Text(session.device.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                if session.loading { ProgressView().controlSize(.small).help(L10n.text("Reading device information…")) }
                Button { session.refresh() } label: { Label(L10n.text("刷新"), systemImage: "arrow.clockwise") }.disabled(session.loading)
            }.padding(14).modifier(AdaptiveGlass(radius: 14))
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("Search fields and values"), text: $search).textFieldStyle(.plain)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help(L10n.text("Clear search")) }
                Divider().frame(height: 18)
                Button { if let text = session.information?.report() { session.copy(text) } } label: { Label(L10n.text("Copy all information"), systemImage: "doc.on.doc") }.disabled(session.information == nil)
                Button { session.export() } label: { Label(L10n.text("Export"), systemImage: "square.and.arrow.up") }.disabled(session.information == nil)
            }.padding(12).modifier(AdaptiveCard(radius: 12))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let info = session.information {
                        if !info.warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(info.warnings.enumerated()), id: \.offset) { _, warning in
                                    Label(warning, systemImage: "info.circle").textSelection(.enabled)
                                }
                            }.font(.caption).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(AdaptiveCard(radius: 12))
                        }
                        ForEach(info.sections) { section in
                            let fields = section.fields.filter(matches)
                            if !fields.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(L10n.text(section.id)).font(.headline)
                                    Text(L10n.text("Source") + ": " + section.source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    ForEach(fields) { field in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(L10n.text(field.id)).font(.callout).foregroundStyle(.secondary).frame(width: 170, alignment: .leading).textSelection(.enabled)
                                            Text(field.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                            if field.isPath && FileManager.default.fileExists(atPath: field.value) {
                                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: field.value)]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help(L10n.text("在访达中显示"))
                                            }
                                            Button { session.copy(field.value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help(L10n.text("Copy value"))
                                        }
                                        if field.id != fields.last?.id { Divider() }
                                    }
                                }.padding(16).modifier(AdaptiveCard(radius: 12))
                            }
                        }
                        if !search.isEmpty && !info.sections.contains(where: { $0.fields.contains(where: matches) }) {
                            Text(L10n.text("No matching information")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                        }
                        if !info.raw.isEmpty {
                            DisclosureGroup(L10n.text("Raw information"), isExpanded: $showRaw) {
                                VStack(alignment: .leading, spacing: 18) {
                                    ForEach(info.raw) { item in
                                        HStack { Text(item.id).font(.caption.weight(.semibold)).textSelection(.enabled); Spacer(); Button(L10n.text("Copy")) { session.copy(item.text) } }
                                        Text(item.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.padding(.top, 12)
                            }.padding(16).modifier(AdaptiveCard(radius: 12))
                        }
                    } else { Text(L10n.text("Reading device information…")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(L10n.text("Read-only · Does not start the simulator"))
                Spacer()
                if let info = session.information { Text(L10n.text("Last refreshed") + " " + info.date.formatted(date: .numeric, time: .standard)) }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(minWidth: 760, minHeight: 520)
            .background(Color(nsColor: .windowBackgroundColor)).modifier(AppAppearanceModifier())
            .environment(\.locale, Locale(identifier: language == "system" ? L10n.language : language))
            .alert(L10n.text("操作失败"), isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) { Button(L10n.text("好")) { session.error = nil } } message: { Text(session.error ?? "") }
    }
}

@MainActor final class DeviceInformationWindowManager {
    private let store: Store
    private var windows: [String: DeviceInformationWindow] = [:]
    init(store: Store) { self.store = store }
    func show(_ device: Device) {
        if let existing = windows[device.id] { existing.reveal(); return }
        let session = DeviceInformationSession(device: device, store: store)
        let controller = DeviceInformationWindow(session: session) { [weak self] in self?.windows.removeValue(forKey: device.id) }
        windows[device.id] = controller; controller.reveal(); session.refresh()
    }
    func updateTitles() { for window in windows.values { window.updateTitle() } }
    func closeAll() { for window in windows.values { window.session.close() } }
}
@MainActor private final class DeviceInformationWindow: NSWindowController, NSWindowDelegate {
    let session: DeviceInformationSession
    let onClose: () -> Void
    init(session: DeviceInformationSession, onClose: @escaping () -> Void) {
        self.session = session; self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: DeviceInformationView(session: session))
        window.setContentSize(NSSize(width: 900, height: 700))
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.initialFirstResponder = nil; window.delegate = self; window.center(); updateTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateTitle() { window?.title = L10n.text("Device information") + " — " + session.device.name }
    func reveal() { NSApp.activate(ignoringOtherApps: true); if window?.isMiniaturized == true { window?.deminiaturize(nil) }; window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(nil) }
    func windowWillClose(_ notification: Notification) { session.close(); onClose() }
}
