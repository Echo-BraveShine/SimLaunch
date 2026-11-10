import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers
import SimLaunchCore

struct ApplicationSandboxView: View {
    private enum FileAction {
        case preview
        case openWith(URL)
        case export(URL)

        var isPreview: Bool {
            if case .preview = self { return true }
            return false
        }

        var progressLabel: String {
            switch self {
            case .preview: return L10n.text("Preparing preview…")
            case .openWith: return L10n.text("Preparing file…")
            case .export: return L10n.text("Exporting file…")
            }
        }
    }

    let app: InstalledApplication
    @ObservedObject var session: ApplicationManagementSession
    @State private var components: [String] = []
    @State private var directory: SandboxDirectory?
    @State private var error: String?
    @State private var loading = false
    @State private var request: Task<Void, Never>?
    @State private var transfer: Task<Void, Never>?
    @State private var transferID = UUID()
    @State private var transferLabel: String?
    @State private var transferError: String?
    @State private var previewURL: URL?
    @State private var exported: URL?
    @State private var importSummary: String?
    @State private var dropTargeted = false
    @State private var targetedFolder: Data?

    private var available: Bool { session.ready && !session.installing && session.uninstalling == nil }
    private var canImport: Bool { available && directory != nil && !loading && transfer == nil }
    private var path: String {
        let root = session.device.platform == .HarmonyOS ? "./data/storage/el2/base" : "."
        return ([root] + components).joined(separator: "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    components.removeLast()
                    load()
                } label: {
                    Label(L10n.text("Parent folder"), systemImage: "arrow.up")
                }
                .disabled(components.isEmpty || !available || transfer != nil)
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    .help(path)
                Spacer(minLength: 4)
                Button(action: chooseImportFiles) {
                    Label(L10n.text("Import Files…"), systemImage: "square.and.arrow.up")
                }
                .disabled(!canImport)
                RefreshButton(isLoading: loading, isDisabled: !available || transfer != nil) { load() }
            }
            .padding(10).modifier(AdaptiveCard(radius: 12))

            if !available {
                notice(L10n.text("Connect the simulator to browse the app sandbox."), icon: "info.circle")
            } else if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .lineLimit(5).help(error)
                    if session.device.platform == .Android {
                        Text(L10n.text("Sandbox access requires a debuggable Android app."))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
            } else if let directory {
                if directory.entries.isEmpty {
                    notice(L10n.text("This folder is empty."), icon: "folder")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(directory.entries) { entry in
                                entryRow(entry)
                                Divider()
                            }
                        }.padding(.horizontal, 10)
                    }
                    .frame(maxHeight: .infinity)
                    .modifier(AdaptiveCard(radius: 12))
                }
                if directory.truncated {
                    Text(L10n.text("This folder has more entries than can be displayed."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Spacer(minLength: 0)
            }
            transferStatus
        }
        .modifier(SandboxDropHighlight(active: dropTargeted && targetedFolder == nil && canImport, radius: 12))
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            acceptDrop(providers, into: components)
        }
        .onAppear { load() }
        .onDisappear { request?.cancel(); cancelTransfer(); previewURL = nil }
        .onChange(of: available) { _ in load() }
        .quickLookPreview($previewURL)
    }

    @ViewBuilder private var transferStatus: some View {
        if let transferLabel {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(transferLabel).font(.callout)
                Spacer()
                Button(L10n.text("取消")) { transfer?.cancel() }
            }
        } else if let transferError {
            Label(transferError, systemImage: "exclamationmark.circle")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(3).help(transferError).textSelection(.enabled)
        } else if let exported {
            HStack {
                Label(L10n.text("Sandbox file exported."), systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("在访达中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([exported])
                }
            }
        } else if let importSummary {
            Label(importSummary, systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        } else if available && directory != nil {
            Label(L10n.text("Drop files here or onto a folder to import them."), systemImage: "arrow.down.to.line")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func notice(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func entryRow(_ entry: SandboxDirectory.Entry) -> some View {
        if entry.kind == .directory, !entry.name.contains("\u{FFFD}") {
            Button {
                components.append(entry.name)
                load()
            } label: {
                HStack {
                    Label(entry.name, systemImage: "folder")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(8)
            }.buttonStyle(.plain)
                .disabled(transfer != nil)
                .modifier(SandboxDropHighlight(active: targetedFolder == entry.id && canImport, radius: 8))
                .onDrop(of: [UTType.fileURL], isTargeted: Binding(
                    get: { targetedFolder == entry.id },
                    set: { if $0 { targetedFolder = entry.id } else if targetedFolder == entry.id { targetedFolder = nil } }
                )) { providers in
                    acceptDrop(providers, into: components + [entry.name])
                }
        } else if entry.kind == .file, !entry.name.contains("\u{FFFD}") {
            HStack(spacing: 8) {
                Label(entry.name, systemImage: "doc")
                    .lineLimit(1).truncationMode(.middle).help(entry.name).textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    transferFile(entry.name)
                } label: {
                    Image(systemName: "eye").frame(width: 22, height: 20)
                }
                .help(L10n.text("Preview file")).accessibilityLabel(L10n.text("Preview file"))
                Button {
                    chooseExportLocation(for: entry.name)
                } label: {
                    Image(systemName: "square.and.arrow.down").frame(width: 22, height: 20)
                }
                .help(L10n.text("Export file…")).accessibilityLabel(L10n.text("Export file…"))
            }
            .buttonStyle(.borderless)
            .contextMenu {
                Button(L10n.text("Preview file")) { transferFile(entry.name) }
                Button(L10n.text("Open with App…")) { chooseApplication(for: entry.name) }
                Button(L10n.text("Export file…")) { chooseExportLocation(for: entry.name) }
            }
            .disabled(!available || transfer != nil)
            .padding(8)
        } else {
            Label(entry.name, systemImage: entry.kind == .link ? "link" : "doc")
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }

    private func chooseImportFiles() {
        guard canImport else { return }
        let path = components
        let panel = NSOpenPanel()
        panel.title = L10n.text("Import Files…")
        panel.prompt = L10n.text("Import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            importFiles(into: path) { panel.urls }
        }
        presentFilePanel(panel, completion: completion)
    }

    private func acceptDrop(_ providers: [NSItemProvider], into path: [String]) -> Bool {
        guard canImport, !providers.isEmpty else { return false }
        importFiles(into: path) {
            var urls: [URL] = []
            for provider in providers {
                try Task.checkCancellation()
                let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                        if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: error ?? CLIError(L10n.text("The dropped file could not be read."))) }
                    }
                }
                guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                    throw CLIError(L10n.text("The dropped file could not be read."))
                }
                urls.append(url)
            }
            return urls
        }
        return true
    }

    private func importFiles(into path: [String], resolve: @escaping () async throws -> [URL]) {
        guard canImport else { return }
        transferError = nil
        exported = nil
        importSummary = nil
        transferLabel = L10n.text("Importing files…")
        let id = UUID()
        transferID = id
        transfer = Task { @MainActor in
            var imported = 0
            var failures: [String] = []
            do {
                let urls = try await resolve()
                for url in urls {
                    try Task.checkCancellation()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        try await session.importSandboxFile(url, for: app, components: path)
                        imported += 1
                    } catch {
                        try Task.checkCancellation()
                        failures.append(url.lastPathComponent + " — " + error.localizedDescription)
                    }
                }
            } catch {
                if !Task.isCancelled { failures.append(error.localizedDescription) }
            }
            guard transferID == id else { return }
            transfer = nil
            transferLabel = nil
            if imported > 0 { importSummary = L10n.format("Files imported: %d", imported) }
            if !failures.isEmpty { transferError = ([importSummary].compactMap { $0 } + failures).joined(separator: "\n") }
            load(keepingTransferStatus: true)
        }
    }

    private func chooseExportLocation(for name: String) {
        guard available, transfer == nil else { return }
        let panel = NSSavePanel()
        panel.title = L10n.text("Export file…")
        panel.prompt = L10n.text("Export")
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            transferFile(name, action: .export(url))
        }
        presentFilePanel(panel, completion: completion)
    }

    private func transferFile(_ name: String, action: FileAction = .preview) {
        guard available, transfer == nil else { return }
        let path = components
        let replacing: Bool
        if case let .export(destination) = action {
            replacing = FileManager.default.fileExists(atPath: destination.path)
        } else {
            replacing = false
        }
        transferError = nil
        exported = nil
        importSummary = nil
        transferLabel = action.progressLabel
        let id = UUID()
        transferID = id
        transfer = Task { @MainActor in
            defer {
                if transferID == id { transfer = nil; transferLabel = nil }
            }
            do {
                let file = try await session.downloadSandboxFile(for: app, components: path, name: name, forPreview: action.isPreview)
                try Task.checkCancellation()
                switch action {
                case let .export(destination):
                    try await file.export(to: destination, replacingExisting: replacing)
                    if !Task.isCancelled { exported = destination }
                case .preview:
                    previewURL = try await makeTemporaryCopy(of: file)
                case let .openWith(application):
                    try await open(file, with: application)
                }
            } catch {
                if !Task.isCancelled { transferError = error.localizedDescription }
            }
        }
    }

    private func cancelTransfer() {
        transfer?.cancel()
        transferID = UUID()
        transfer = nil
        transferLabel = nil
    }

    private func load(keepingTransferStatus: Bool = false) {
        request?.cancel()
        cancelTransfer()
        if !keepingTransferStatus {
            transferError = nil
            exported = nil
            importSummary = nil
        }
        directory = nil
        error = nil
        loading = available
        guard available else { return }
        let path = components
        request = Task { @MainActor in
            do {
                let result = try await session.sandboxDirectory(for: app, components: path)
                guard !Task.isCancelled else { return }
                directory = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func chooseApplication(for name: String) {
        guard available, transfer == nil else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Open with App…")
        panel.message = L10n.text("Choose a Mac app to open the local copy.")
        panel.prompt = L10n.text("Open")
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let app = panel.url else { return }
            transferFile(name, action: .openWith(app))
        }
        presentFilePanel(panel, completion: completion)
    }

    private func presentFilePanel(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        panel.appearance = NSApplication.shared.appearance
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func makeTemporaryCopy(of file: SandboxFile) async throws -> URL {
        let manager = FileManager.default
        // Quick Look can hand the file to another app that reads it after the panel closes.
        let folder = manager.temporaryDirectory.appendingPathComponent("SimLaunch-Preview-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let copy = folder.appendingPathComponent(file.url.lastPathComponent, isDirectory: false)
        do {
            try await file.export(to: copy, replacingExisting: false)
            try Task.checkCancellation()
            return copy
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    private func open(_ file: SandboxFile, with application: URL) async throws {
        let copy = try await makeTemporaryCopy(of: file)
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.allowsRunningApplicationSubstitution = false
            _ = try await NSWorkspace.shared.open([copy], withApplicationAt: application, configuration: configuration)
        } catch {
            try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            throw CLIError(L10n.format("Could not open the file with %@. %@", application.deletingPathExtension().lastPathComponent, error.localizedDescription))
        }
    }
}

struct SandboxDropHighlight: ViewModifier {
    let active: Bool
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            if active {
                let outline = RoundedRectangle(cornerRadius: radius)
                outline.fill(Color.accentColor.opacity(scheme == .dark ? 0.24 : 0.14))
                    .overlay {
                        outline.strokeBorder(Color.accentColor, lineWidth: contrast == .increased ? 3 : 2)
                    }
                    .allowsHitTesting(false)
            }
        }
    }
}
