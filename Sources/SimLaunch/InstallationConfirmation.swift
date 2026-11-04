import SwiftUI
import SimLaunchCore

struct InstallationConfirmation: View {
    let package: PreparedInstallation
    @ObservedObject var session: ApplicationManagementSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language = "system"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.text("Install application?"), systemImage: "plus.app").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text(package.application.displayName).font(.headline)
                Text(package.application.id).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Text([package.application.version, package.application.build].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                Divider()
                Text(L10n.format("Install on %@", session.device.name))
                if let user = session.snapshot?.user { Text(L10n.text("Device user") + ": " + user) }
                Text(ByteCountFormatter.string(fromByteCount: package.bytes, countStyle: .file)).foregroundStyle(.secondary)
                ScrollView { VStack(alignment: .leading, spacing: 4) { ForEach(Array(package.fileNames.enumerated()), id: \.offset) { _, name in Text(name).font(.caption).textSelection(.enabled) } } }.frame(maxHeight: 90)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(AdaptiveCard(radius: 12))
            if session.snapshot?.applications.contains(where: { $0.id == package.application.id }) == true {
                Label(L10n.text("An installed application has the same identifier. This will attempt to update it."), systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(.secondary)
            }
            if session.installing { HStack { ProgressView().controlSize(.small); Text(L10n.text(session.installationPhase)) } }
            if let error = session.error { ScrollView { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110) }
            if !session.ready { Text(L10n.text("App details are cached while the device is offline.")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.disabled(session.installing)
                Button(L10n.text("Install")) { session.install(package) }
                    .keyboardShortcut(.defaultAction).disabled(!session.ready || session.installing || session.uninstalling != nil)
            }
        }.padding(20).frame(width: 480).background(Color(nsColor: .windowBackgroundColor))
            .modifier(AppAppearanceModifier())
            .interactiveDismissDisabled(session.installing)
            .onChange(of: session.installedID) { id in if id == package.application.id && !session.installing { dismiss() } }
            .environment(\.locale, Locale(identifier: language == "system" ? L10n.language : language))
    }
}
