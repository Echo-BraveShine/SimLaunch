import SwiftUI
import AppKit
import Combine
import ImageIO
import SimLaunchCore

@MainActor final class ApplicationManagementSession: ObservableObject {
    let device: Device
    let identity: String
    private weak var store: Store?
    private let makeService: (Configuration) -> ApplicationService
    @Published private(set) var snapshot: ApplicationSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var readingDetails = false
    @Published private(set) var ready: Bool
    @Published private(set) var current = false
    @Published private(set) var uninstalling: String?
    @Published private(set) var error: String?
    @Published private(set) var incompleteDetails = false
    private var task: Task<Void, Never>?
    private var mutation: Task<Void, Never>?
    private var detailRequest: Task<InstalledApplication, Error>?
    private var detailRequestID = UUID()
    private var iconTask: Task<Void, Never>?
    private var iconRunID = UUID()
    private var visibleIDs: Set<String> = []
    private var metadataReady: Set<String> = []
    private var iconAttempted: Set<String> = []
    private var iconConnection: DeviceToolConnection?
    private var iconService: ApplicationService?
    private var forceIconReload = false
    private var metadataLoading = false
    private var detailOverrides: Set<String> = []
    private var observation: AnyCancellable?
    private var generation = UUID()
    var cacheKey: String { identity + "|" + L10n.language }
    init(device: Device, store: Store, serviceFactory: ((Configuration) -> ApplicationService)? = nil) {
        let expected = LogConnection.fingerprint(device)
        makeService = serviceFactory ?? { ApplicationService(device: device, configuration: $0, identity: expected) }
        self.device = device; self.store = store; identity = LogConnection.fingerprint(device); ready = device.state == .running
        observation = store.$devices.sink { [weak self] devices in
            guard let self else { return }
            self.ready = devices.contains { $0.id == device.id && $0.state == .running && LogConnection.fingerprint($0) == self.identity }
            if !self.ready { self.generation = UUID(); self.task?.cancel(); self.iconTask?.cancel(); self.iconTask = nil; self.detailRequest?.cancel(); self.loading = false; self.readingDetails = false; self.current = false }
        }
    }
    func canUninstall(_ app: InstalledApplication) -> Bool { ready && current && !loading && uninstalling == nil && app.canUninstall }
    func refresh(forceIcons: Bool = false) {
        guard ready, uninstalling == nil, let store else { return }
        task?.cancel(); iconTask?.cancel(); iconTask = nil; generation = UUID(); detailOverrides.removeAll(); metadataReady.removeAll(); iconAttempted.removeAll(); forceIconReload = forceIcons
        let generation = generation, key = cacheKey
        let service = makeService(store.config)
        metadataLoading = true; iconService = nil; iconConnection = nil
        loading = true; readingDetails = false; current = false; error = nil; incompleteDetails = false
        task = Task { [weak self] in
            guard let self else { return }
            if self.snapshot == nil { self.snapshot = await ApplicationCache.shared.get(key) }
            do {
                var fresh = try await service.list()
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                let previous = Dictionary((self.snapshot?.applications ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                for i in fresh.applications.indices {
                    if let cached = previous[fresh.applications[i].id] {
                        fresh.applications[i] = fresh.applications[i].reusingPresentation(cached)
                    }
                }
                if forceIcons { for i in fresh.applications.indices { fresh.applications[i].icon = nil } }
                self.snapshot = fresh; self.current = true; self.loading = false; self.readingDetails = true
                await ApplicationCache.shared.set(fresh, for: key)
                let connection = try await service.metadataConnection()
                self.iconConnection = connection; self.iconService = service
                var remaining = fresh.applications.sorted { ($0.kind == .user ? 0 : 1, $0.id) < ($1.kind == .user ? 0 : 1, $1.id) }.makeIterator()
                await withTaskGroup(of: (String, InstalledApplication?).self) { group in
                    func add(_ app: InstalledApplication) {
                        group.addTask {
                            guard !Task.isCancelled else { return (app.id, nil) }
                            return (app.id, try? await service.metadata(app, snapshot: fresh, connection: connection, loadIcon: false, bypassIconCache: forceIcons))
                        }
                    }
                    for _ in 0..<4 { if let app = remaining.next() { add(app) } }
                    while let (id, enriched) = await group.next() {
                        guard !Task.isCancelled, self.generation == generation else { group.cancelAll(); return }
                        if let enriched, let i = self.snapshot?.applications.firstIndex(where: { $0.id == id }) { if !self.detailOverrides.contains(id) { self.snapshot?.applications[i] = enriched }
                            self.metadataReady.insert(id); self.loadVisibleIcons() }
                        else { self.incompleteDetails = true }
                        if let app = remaining.next() { add(app) }
                    }
                }
                guard !Task.isCancelled, self.generation == generation else { return }
                self.metadataLoading = false
                self.loadVisibleIcons()
                self.readingDetails = self.iconTask != nil
                if let snapshot = self.snapshot { await ApplicationCache.shared.set(snapshot, for: key) }
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.loading = false; self.readingDetails = false; self.current = false; self.error = error.localizedDescription
            }
        }
    }
    func setVisible(_ id: String, visible: Bool) {
        if visible { visibleIDs.insert(id); loadVisibleIcons() } else { visibleIDs.remove(id) }
    }
    private func loadVisibleIcons() {
        guard iconTask == nil, ready, let service = iconService, let connection = iconConnection, let snapshot else { return }
        let needsIcon = snapshot.applications.contains { (visibleIDs.contains($0.id) || !metadataLoading) && metadataReady.contains($0.id) && !iconAttempted.contains($0.id) && ($0.icon == nil || forceIconReload) }
        guard needsIcon else { return }
        let generation = generation, run = UUID(), force = forceIconReload
        iconRunID = run; readingDetails = true
        iconTask = Task { [weak self] in
            guard let self else { return }
            await Task.yield() // Coalesce rows that became visible in the same layout pass.
            while !Task.isCancelled && self.ready && self.generation == generation {
                let limit = self.device.platform == .Android ? 8 : 2
                let pending = Array((self.snapshot?.applications ?? []).filter { (self.visibleIDs.contains($0.id) || !self.metadataLoading) && self.metadataReady.contains($0.id) && !self.iconAttempted.contains($0.id) && ($0.icon == nil || force) }.sorted { (self.visibleIDs.contains($0.id) ? 0 : 1, $0.id) < (self.visibleIDs.contains($1.id) ? 0 : 1, $1.id) }.prefix(limit))
                guard !pending.isEmpty else { break }
                for app in pending { self.iconAttempted.insert(app.id) }
                let results = await service.icons(pending, snapshot: snapshot, connection: connection, force: force)
                guard !Task.isCancelled && self.generation == generation else { break }
                for app in results {
                    if !self.detailOverrides.contains(app.id), let i = self.snapshot?.applications.firstIndex(where: { $0.id == app.id }) { self.snapshot?.applications[i] = app }
                }
            }
            guard self.iconRunID == run, self.generation == generation else { return }
            self.iconTask = nil
            self.readingDetails = self.metadataLoading
            if let snapshot = self.snapshot { await ApplicationCache.shared.set(snapshot, for: self.cacheKey) }
        }
    }
    func uninstall(_ app: InstalledApplication) {
        guard canUninstall(app), let snapshot, let store else { return }
        task?.cancel(); iconTask?.cancel(); iconTask = nil; generation = UUID(); readingDetails = false; uninstalling = app.id; error = nil
        let key = cacheKey, service = makeService(store.config)
        mutation = Task { [weak self] in
            await ApplicationCache.shared.remove(key)
            do {
                let result = try await service.uninstall(app, snapshot: snapshot)
                guard !Task.isCancelled, let self else { return }
                self.snapshot = result; self.current = self.ready; self.uninstalling = nil
                await ApplicationCache.shared.set(result, for: key)
                if self.ready { self.refresh() }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.uninstalling = nil; self.current = false; self.error = error.localizedDescription
            }
        }
    }
    func details(_ app: InstalledApplication, forceIcon: Bool = false) async throws -> InstalledApplication {
        guard ready, let store, let snapshot else { throw CLIError(L10n.text("App details are cached while the device is offline.")) }
        detailRequest?.cancel(); detailRequestID = UUID()
        let requestID = detailRequestID, service = makeService(store.config)
        let request = Task { try await service.details(app, snapshot: snapshot, forceIcon: forceIcon) }
        detailRequest = request
        defer { if detailRequestID == requestID { detailRequest = nil } }
        let result = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
        try Task.checkCancellation()
        guard ready else { throw CLIError(L10n.text("App details are cached while the device is offline.")) }
        detailOverrides.insert(result.id)
        if let index = self.snapshot?.applications.firstIndex(where: { $0.id == result.id }) { self.snapshot?.applications[index] = result }
        if let snapshot = self.snapshot { await ApplicationCache.shared.set(snapshot, for: cacheKey) }
        return result
    }
    func close() { generation = UUID(); task?.cancel(); mutation?.cancel(); iconTask?.cancel(); detailRequest?.cancel(); loading = false; readingDetails = false; observation = nil }
    deinit { task?.cancel(); mutation?.cancel(); iconTask?.cancel(); detailRequest?.cancel() }
}

private enum ApplicationFilter: String, CaseIterable { case user = "User applications", system = "System applications", all = "All applications" }
struct ApplicationManagementView: View {
    @ObservedObject var session: ApplicationManagementSession
    @AppStorage("appLanguage") private var language = "system"
    @State private var search = ""
    @State private var filter = ApplicationFilter.all
    @State private var candidate: InstalledApplication?
    @State private var detailCandidate: InstalledApplication?
    private var apps: [InstalledApplication] {
        (session.snapshot?.applications ?? []).filter { app in
            (filter == .all || (filter == .user && app.kind == .user) || (filter == .system && app.kind == .system)) && (search.isEmpty || app.displayName.localizedCaseInsensitiveContains(search) || app.id.localizedCaseInsensitiveContains(search))
        }.sorted { $0.id < $1.id }
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                PlatformIcon(platform: session.device.platform, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Application management")).font(.title3.weight(.semibold))
                    Text(session.device.name + " · " + session.device.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                RefreshButton(isLoading: session.loading || session.readingDetails || session.uninstalling != nil,
                              isDisabled: !session.ready,
                              loadingLabel: session.uninstalling != nil ? "Uninstalling application…" : "Refreshing…") {
                    session.refresh(forceIcons: true)
                }
            }.padding(14).modifier(AdaptiveGlass(radius: 14))
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("Search application name or identifier"), text: $search).textFieldStyle(.plain)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help(L10n.text("Clear search")) }
                Divider().frame(height: 20)
                Picker(L10n.text("Application type"), selection: $filter) { ForEach(ApplicationFilter.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) } }.labelsHidden().frame(width: 170)
            }.padding(12).modifier(AdaptiveCard(radius: 12))
            if !session.ready {
                notice(L10n.text("The device is offline. The list is retained; application operations are disabled."), symbol: "wifi.slash")
            } else if let error = session.error { notice(error, symbol: "exclamationmark.triangle") }
            else if !session.current && session.snapshot != nil { notice(L10n.text("Showing a cached list. Refreshing before enabling uninstall."), symbol: "clock") }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(apps) { app in applicationRow(app).onAppear { session.setVisible(app.id, visible: true) }.onDisappear { session.setVisible(app.id, visible: false) } }
                    if apps.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "square.grid.2x2").font(.system(size: 30)).foregroundStyle(.tertiary)
                            Text(L10n.text(session.loading || session.readingDetails ? "Reading applications…" : !search.isEmpty ? "No matching applications" : "No applications in this category")).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                }.padding(2)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.format("%d applications shown", apps.count))
                    Text(L10n.text(session.incompleteDetails ? "Some application details could not be read." : "Names and icons appear when metadata is accessible."))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if session.uninstalling != nil { Text(L10n.text("Uninstalling application…")) }
                    else if session.readingDetails { Text(L10n.text("Reading application details…")) }
                    else if let snapshot = session.snapshot { Text(L10n.text("Last refreshed") + " " + snapshot.date.formatted(date: .omitted, time: .standard)) }
                    if let user = session.snapshot?.user { Text(L10n.text("Device user") + " " + user) }
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(minWidth: 720, minHeight: 480)
            .background(Color(nsColor: .windowBackgroundColor)).modifier(AppAppearanceModifier())
            .environment(\.locale, Locale(identifier: language == "system" ? L10n.language : language))
            .sheet(item: $detailCandidate) { app in ApplicationDetailView(app: app, session: session) }
            .alert(L10n.text("Uninstall application?"), isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } }), presenting: candidate) { app in
                Button(L10n.text("Uninstall"), role: .destructive) { session.uninstall(app) }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: { app in
                Text(L10n.format("Uninstall “%@” (%@) from “%@”? A running application will be closed and its data may be deleted.", app.displayName, app.id, session.device.name))
            }
    }
    private func notice(_ message: String, symbol: String) -> some View {
        Label(message, systemImage: symbol).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12).modifier(AdaptiveCard(radius: 12))
    }
    private func applicationRow(_ app: InstalledApplication) -> some View {
        HStack(spacing: 12) {
            ApplicationIcon(data: app.icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                if app.name?.isEmpty == false { Text(app.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled) }
                if app.version != nil || app.build != nil { Text([app.version, app.build.map { L10n.text("Build number") + " " + $0 }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 10)
            if app.kind != .user { Text(L10n.text(app.kind == .system ? "System application" : "Application type unknown")).font(.caption).foregroundStyle(.secondary) }
            Button { detailCandidate = app } label: { Label(L10n.text("App details"), systemImage: "info.circle") }
                .disabled(session.uninstalling == app.id)
            if session.uninstalling == app.id { ProgressView().controlSize(.mini).frame(width: 70) }
            else {
                Button(role: .destructive) { candidate = app } label: { Label(L10n.text("Uninstall"), systemImage: "trash") }
                    .disabled(!session.canUninstall(app))
                    .help(L10n.text(app.canUninstall ? "Uninstall this application from the selected device." : "System applications and applications of unknown type cannot be uninstalled."))
            }
        }.padding(12).modifier(AdaptiveCard(radius: 12))
    }
}

struct ApplicationIcon: View {
    let data: Data?
    private var image: NSImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(width: 44, height: 44))
    }
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "app.dashed").font(.system(size: 25)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.primary.opacity(0.04)) }
        }.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor final class ApplicationManagementWindowManager {
    private let store: Store
    private var windows: [String: ApplicationManagementWindow] = [:]
    init(store: Store) { self.store = store }
    func show(_ device: Device) {
        guard device.state == .running else { return }
        if let existing = windows[device.id] {
            if existing.session.identity == LogConnection.fingerprint(device) { existing.reveal(); return }
            existing.close()
        }
        let session = ApplicationManagementSession(device: device, store: store)
        let window = ApplicationManagementWindow(session: session) { [weak self] in self?.windows.removeValue(forKey: device.id) }
        windows[device.id] = window; window.reveal(); session.refresh()
    }
    func updateTitles() { for window in windows.values { window.updateTitle() } }
    func closeAll() { for window in windows.values { window.session.close() } }
}
@MainActor private final class ApplicationManagementWindow: NSWindowController, NSWindowDelegate {
    let session: ApplicationManagementSession
    let onClose: () -> Void
    init(session: ApplicationManagementSession, onClose: @escaping () -> Void) {
        self.session = session; self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: ApplicationManagementView(session: session))
        window.setContentSize(NSSize(width: 850, height: 650)); window.contentMinSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.initialFirstResponder = nil; window.delegate = self; window.center(); updateTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateTitle() { window?.title = L10n.text("Application management") + " — " + session.device.name }
    func reveal() { NSApp.activate(ignoringOtherApps: true); if window?.isMiniaturized == true { window?.deminiaturize(nil) }; window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(nil) }
    func windowWillClose(_ notification: Notification) { session.close(); onClose() }
}
