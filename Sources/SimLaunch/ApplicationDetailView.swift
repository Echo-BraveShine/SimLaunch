import SwiftUI
import AppKit
import SimLaunchCore

struct ApplicationDetailView: View {
    @ObservedObject var session: ApplicationManagementSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language = "system"
    @State private var information: InstalledApplication
    @State private var loading = false
    @State private var openingSandbox = false
    @State private var browsingSandbox = false
    @State private var error: String?
    @State private var updated: Date?
    @State private var request: Task<Void, Never>?
    init(app: InstalledApplication, session: ApplicationManagementSession) {
        _information = State(initialValue: app); self.session = session
    }
    private var fields: [(String, String)] {
        let unknown = L10n.text("Not provided")
        var fields = [
            ("Application name", information.name ?? unknown),
            (session.device.platform == .Android ? "Package name" : "Bundle ID", information.id),
            ("Version name", information.version ?? unknown),
            ("Build number", information.build ?? unknown),
            ("Application type", L10n.text(information.kind == .user ? "User application" : information.kind == .system ? "System application" : "Application type unknown")),
            ("Icon status", L10n.text(information.icon == nil ? "Placeholder icon" : "Application icon loaded")),
            ("Device name", session.device.name)
        ]
        if let user = session.snapshot?.user { fields.append(("Device user", user)) }
        if let path = information.bundlePath { fields.append(("Application path", path)) }
        return fields
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ApplicationIcon(data: information.icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(information.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(L10n.text(browsingSandbox ? "App sandbox" : "App details") + " · " + session.device.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.device.platform == .iOS {
                    Button(action: openSandbox) {
                        ZStack {
                            Label(L10n.text("Open Sandbox in Finder"), systemImage: "folder")
                                .opacity(openingSandbox ? 0 : 1)
                            if openingSandbox { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                        }
                    }
                    .help(L10n.text("Open Sandbox in Finder"))
                    .accessibilityLabel(L10n.text("Open Sandbox in Finder"))
                    .disabled(openingSandbox || loading || !session.ready || session.installing || session.uninstalling != nil)
                } else if browsingSandbox {
                    Button { browsingSandbox = false } label: { Label(L10n.text("App details"), systemImage: "chevron.left") }
                } else {
                    Button { browsingSandbox = true } label: { Label(L10n.text("Browse Sandbox"), systemImage: "folder") }
                        .disabled(!session.ready || session.snapshot == nil || session.installing || session.uninstalling != nil)
                }
                if !browsingSandbox {
                    RefreshButton(isLoading: loading, isDisabled: openingSandbox || !session.ready || session.uninstalling != nil) { refresh(forceIcon: true) }
                }
            }.padding(14).modifier(AdaptiveGlass(radius: 14))
            if browsingSandbox {
                ApplicationSandboxView(app: information, session: session)
            } else {
                detailContent
            }
            HStack {
                if !browsingSandbox, let updated {
                    Text(L10n.text("Last refreshed") + " " + updated.formatted(.dateTime.hour().minute().second().locale(Locale(identifier: L10n.language))))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !browsingSandbox {
                    Button { copy((fields + (information.extra ?? [:]).keys.sorted().map { ($0, localizedValue(information.extra![$0]!, field: $0)) }).map { L10n.text($0.0) + ": " + $0.1 }.joined(separator: "\n") + "\n" + (information.notes ?? []).map { L10n.text($0) }.joined(separator: "\n")) } label: { Label(L10n.text("Copy all information"), systemImage: "doc.on.doc") }
                }
                Button(L10n.text("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 640, height: 570)
            .background(Color(nsColor: .windowBackgroundColor)).modifier(AppAppearanceModifier())
            .environment(\.locale, Locale(identifier: language == "system" ? L10n.language : language))
            .onAppear { refresh() }
            .onDisappear { request?.cancel() }
            .onChange(of: session.ready) { ready in
                if !ready {
                    request?.cancel()
                    loading = false
                    openingSandbox = false
                }
            }
    }
    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !session.ready || error != nil || updated == nil {
                    Label(!session.ready ? L10n.text("App details are cached while the device is offline.") : error ?? L10n.text("Showing saved app details while checking current metadata."), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).modifier(AdaptiveCard(radius: 12))
                }
                fieldCard(fields)
                if let extra = information.extra, !extra.isEmpty { fieldCard(extra.keys.sorted().map { ($0, localizedValue(extra[$0]!, field: $0)) }) }
                if let notes = information.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Metadata availability")).font(.headline)
                        ForEach(notes, id: \.self) { Text(L10n.text($0)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).modifier(AdaptiveCard(radius: 12))
                }
            }.padding(2)
        }
    }
    private func localizedValue(_ value: String, field: String) -> String {
        switch field {
        case "Metadata source", "Icon source":
            return L10n.text(value)
        case "Icon diagnostic":
            return value.components(separatedBy: "\n").map { L10n.text($0) }.joined(separator: "\n")
        case "appProvisionType":
            switch value {
            case "debug": return L10n.text("Debug signing")
            case "release": return L10n.text("Release signing")
            default: return value
            }
        default:
            return value
        }
    }
    private func fieldCard(_ values: [(String, String)]) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, field in
                HStack(alignment: .top, spacing: 12) {
                    Text(L10n.text(field.0)).font(.callout).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                    Text(field.1).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { copy(field.1) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help(L10n.text("Copy value"))
                }
                if index < values.count - 1 { Divider() }
            }
        }.padding(14).modifier(AdaptiveCard(radius: 12))
    }
    private func refresh(forceIcon: Bool = false) {
        guard session.ready, session.uninstalling == nil else { return }
        request?.cancel(); loading = true; error = nil
        request = Task { @MainActor in
            do {
                let result = try await session.details(information, forceIcon: forceIcon)
                guard !Task.isCancelled else { return }
                information = result; updated = Date(); loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
    }
    private func openSandbox() {
        openingSandbox = true
        error = nil
        request = Task { @MainActor in
            defer { if !Task.isCancelled { openingSandbox = false } }
            do {
                let url = try await session.dataContainer(for: information)
                try Task.checkCancellation()
                if !NSWorkspace.shared.open(url) {
                    throw CLIError(L10n.text("Finder could not open the application sandbox."))
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}
