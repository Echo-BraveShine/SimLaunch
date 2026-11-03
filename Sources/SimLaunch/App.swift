import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SimLaunchCore

@MainActor final class Store: ObservableObject {
    @Published var config: Configuration
    @Published var devices: [Device] = []
    @Published var errors: [String] = []
    @Published var operationError: String?
    @Published var refreshing = false
    @Published private(set) var manuallyRefreshing = false
    @Published private(set) var hasRefreshed = false
    @Published var busy: Set<String> = []
    @Published private(set) var recentDeviceIDs: [String] = UserDefaults.standard.stringArray(forKey: "recentDeviceIDs") ?? []
    var recentDevices: [Device] {
        Array(recentDeviceIDs.compactMap { id in devices.first { $0.id == id && $0.state != .unavailable } }.prefix(5))
    }
    private func recordUsage(_ id: String) {
        recentDeviceIDs.removeAll { $0 == id }
        recentDeviceIDs.insert(id, at: 0)
        UserDefaults.standard.set(recentDeviceIDs, forKey: "recentDeviceIDs")
    }
    private var pending: [String: (DeviceState, Date)] = [:]
    private let launches = LaunchManager()
    private let androidRegistry = AndroidRegistry()
    private let androidMetadata = AndroidMetadataCache()
    init() {
        config = (UserDefaults.standard.data(forKey: "configuration").flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }) ?? Configuration()
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }
    func provider(_ platform: Platform) -> any DeviceProvider {
        switch platform { case .iOS: return IOSProvider(config); case .Android: return AndroidProvider(config, launches: launches, registry: androidRegistry, metadata: androidMetadata); case .HarmonyOS: return HarmonyProvider(config, launches: launches) }
    }
    func provider(_ device: Device) -> any DeviceProvider {
        device.backend == .mumu ? MuMuProvider(config) : provider(device.platform)
    }
    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: "configuration")
        Task { await refresh() }
    }
    func refresh(manual: Bool = false) async {
        guard !refreshing else {
            // A manual click joins an active background query instead of starting another.
            if manual { manuallyRefreshing = true }
            return
        }
        refreshing = true
        manuallyRefreshing = manual
        defer { refreshing = false; manuallyRefreshing = false; hasRefreshed = true }
        var next: [Device] = []; var failures: [String] = []
        for platform in Platform.allCases {
            do { next += try await provider(platform).list() }
            catch {
                failures.append("\(platform.rawValue)：\(error.localizedDescription)")
                next += devices.filter { $0.platform == platform && $0.backend == .standard }.map { var d = $0; d.state = .unknown; return d }
            }
        }
        do { next += try await MuMuProvider(config).listIfInstalled() }
        catch {
            failures.append("MuMu：" + error.localizedDescription)
            next += devices.filter { $0.backend == .mumu }.map { var d = $0; d.state = .unknown; return d }
        }
        for (id, transition) in pending {
            if let d = next.first(where: { $0.id == id }), d.state == transition.0 {
                if transition.0 == .running { recordUsage(id) }
                pending.removeValue(forKey: id); busy.remove(id)
            }
            else if Date() > transition.1 {
                failures.append(L10n.format("Device transition timed out: %@. Check ~/Library/Logs/SimLaunch or the development tool logs.", id))
                pending.removeValue(forKey: id); busy.remove(id)
            }
        }
        devices = next; errors = failures
    }
    func reveal(_ device: Device) {
        Task {
            do { try await IOSProvider(config).reveal(device); recordUsage(device.id) }
            catch { operationError = error.localizedDescription }
        }
    }
    func showInFinder(_ device: Device) {
        guard let directory = device.directory, FileManager.default.fileExists(atPath: directory) else {
            operationError = L10n.text("设备目录不存在或无法定位，请刷新后重试"); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
    }
    func delete(_ device: Device) {
        guard !busy.contains(device.id) else { return }
        busy.insert(device.id)
        Task {
            defer { busy.remove(device.id) }
            do {
                let source = provider(device)
                let current = try await source.list()
                guard let fresh = current.first(where: { $0.id == device.id }) else { throw CLIError(L10n.text("设备已消失，请刷新")) }
                guard device.backend != .mumu || LogConnection.fingerprint(device) == LogConnection.fingerprint(fresh) else {
                    throw CLIError(L10n.text("Device identity changed. Reopen device information from the device list."))
                }
                try DeviceDeletion.validate(fresh)
                try await source.delete(fresh)
                devices.removeAll { $0.id == device.id }
                recentDeviceIDs.removeAll { $0 == device.id }
                UserDefaults.standard.set(recentDeviceIDs, forKey: "recentDeviceIDs")
                await refresh()
            } catch { operationError = error.localizedDescription }
        }
    }
    func toggle(_ device: Device, mode: BootMode = .normal) {
        guard !busy.contains(device.id) else { return }
        if mode == .cold && (!device.supportsColdBoot || device.state != .stopped) { return }
        busy.insert(device.id)
        Task {
            do {
                // Recheck authoritative state immediately before mutation.
                let current = try await provider(device).list()
                guard let fresh = current.first(where: { $0.id == device.id }) else { throw CLIError(L10n.text("设备已消失，请刷新")) }
                guard device.backend != .mumu || LogConnection.fingerprint(device) == LogConnection.fingerprint(fresh) else {
                    throw CLIError(L10n.text("Device identity changed. Reopen device information from the device list."))
                }
                let stop = device.state == .running
                if stop && fresh.state == .running { try await provider(device).stop(fresh) }
                else if !stop && fresh.state == .stopped { try await provider(device).start(fresh, mode: mode) }
                else { throw CLIError(L10n.text("设备状态已变化，请刷新后重试")) }
                pending[device.id] = (stop ? .stopped : .running, Date().addingTimeInterval(120))
                await refresh()
            } catch { busy.remove(device.id); operationError = error.localizedDescription }
        }
    }
}

@main struct SimLaunchApp {
    @MainActor static func main() {
        AppPreferences.migrateIfNeeded()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        (AppAppearance(rawValue: UserDefaults.standard.string(forKey: AppAppearance.storageKey) ?? "") ?? .system).apply()
        let delegate = SimLaunchAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
struct Panel: View {
    var openSettings: () -> Void
    var openLogs: (Device) -> Void
    var openInformation: (Device) -> Void
    var openApplications: (Device) -> Void
    var revealInFinder: (Device) -> Void
    var listHeight: CGFloat = 480
    @AppStorage("appLanguage") private var language = "system"
    @State private var deletionCandidate: Device?
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: AppBrand.icon).resizable().frame(width: 30, height: 30)
                Text("SimLaunch").font(.title2.bold()); Spacer()
                RefreshButton(isLoading: store.manuallyRefreshing) { Task { await store.refresh(manual: true) } }
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help(L10n.text("Settings…")).accessibilityLabel(L10n.text("Settings…"))
            }.padding(8).modifier(AdaptiveGlass())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !store.recentDevices.isEmpty {
                        DeviceGroup(id: "recent", title: L10n.text("常用"), count: store.recentDevices.count) {
                            ForEach(store.recentDevices) { device in deviceRow(device, showPlatform: true) }
                        }
                    }
                    ForEach(Platform.allCases) { platform in
                        let devices = store.devices.filter { $0.platform == platform && $0.state != .unavailable }
                        if !devices.isEmpty {
                            DeviceGroup(id: platform.rawValue, title: platform.rawValue, count: devices.count) {
                                ForEach(devices) { device in deviceRow(device) }
                            }
                        }
                    }
                    let unavailable = store.devices.filter { $0.state == .unavailable }
                    if !unavailable.isEmpty {
                        DeviceGroup(id: "unavailable", title: L10n.text("不可用"), count: unavailable.count, initiallyExpanded: false) {
                            ForEach(unavailable) { device in deviceRow(device) }
                        }
                    }
                    if store.devices.isEmpty && store.hasRefreshed && store.errors.isEmpty {
                        Text(L10n.text("未发现设备，请在开发工具中创建，或检查路径设置。")).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }
            }.frame(height: listHeight)
            Divider()
            HStack { Text(L10n.text("仅管理模拟器")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L10n.text("退出")) { NSApp.terminate(nil) } }
        }.padding().frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .modifier(AppAppearanceModifier())
        .environment(\.locale, Locale(identifier: language == "system" ? L10n.language : language))
        .navigationTitle(L10n.text("SimLaunch 设备"))
        .task {
            NSApp.applicationIconImage = AppBrand.icon
            await store.refresh()
        }
        .confirmationDialog(L10n.text("删除设备？"), isPresented: Binding(get: { deletionCandidate != nil }, set: { if !$0 { deletionCandidate = nil } }), titleVisibility: .visible, presenting: deletionCandidate) { device in
            Button(L10n.format("Delete “%@”", device.name), role: .destructive) { store.delete(device) }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: { device in
            Text(L10n.format("Permanently delete %@ device “%@” and all its apps and data? This cannot be undone.", device.platform.rawValue, device.name))
        }
        .alert(L10n.text("操作失败"), isPresented: Binding(get: { store.operationError != nil }, set: { if !$0 { store.operationError = nil } })) {
            Button(L10n.text("好")) { store.operationError = nil }
        } message: { Text(store.operationError ?? "") }
    }
    private func deviceRow(_ device: Device, showPlatform: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(device.name).lineLimit(1)
                    if showPlatform {
                        Text(device.platform.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(store.busy.contains(device.id) ? L10n.text("正在处理…") : L10n.text(device.state.rawValue)).font(.caption).foregroundStyle(.secondary)
                Text(device.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if device.platform == .iOS && device.state == .running {
                Button(L10n.text("显示")) { store.reveal(device) }
            }
            Button(device.state == .running ? L10n.text("停止") : L10n.text("启动")) { store.toggle(device) }
                .disabled(store.busy.contains(device.id) || ![DeviceState.running, .stopped].contains(device.state))
        }.padding(8).modifier(AdaptiveCard(radius: 8))
        .contentShape(Rectangle())
        .help([device.detail, device.serial].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        .contextMenu {
            if device.state == .running {
                Button(L10n.text("Application management")) { openApplications(device) }
            }
            Button(L10n.text("Device information")) { openInformation(device) }
            Button(L10n.text("Live logs")) { openLogs(device) }
                .disabled(device.state == .unavailable)
            Divider()
            Button(L10n.text("在访达中显示")) { revealInFinder(device) }
                .disabled(device.directory == nil)
            Divider()
            Button(L10n.text("复制设备名称")) { copy(device.name) }
            if device.platform == .iOS {
                Button(L10n.text("复制设备 UDID")) { copy(device.key) }
            } else if device.supportsColdBoot {
                Divider()
                Button(L10n.text("冷启动")) { store.toggle(device, mode: .cold) }
                    .disabled(store.busy.contains(device.id) || device.state != .stopped)
            }
            Divider()
            Button(L10n.text("删除当前设备"), role: .destructive) { deletionCandidate = device }
                .disabled(device.isOfflineSnapshot || store.busy.contains(device.id) || (device.state != .stopped && !(device.platform == .iOS && device.state == .unavailable)))
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

}
struct SettingsView: View {
    @ObservedObject private var updates = UpdateController.shared
    @StateObject private var loginItem = LoginItemController()
    @EnvironmentObject var store: Store
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    @State private var selected: Platform? = nil
    @State private var draft = Configuration()
    @State private var saved = false
    @State private var pathError: String?

    private var hasChanges: Bool { draft != store.config }
    private var subtitle: String {
        switch selected {
        case nil: return L10n.text("Language, startup and appearance. Changes apply immediately.")
        case .iOS: return L10n.text("选择 Xcode 与模拟器应用")
        case .Android: return L10n.text("Configure Android SDK and MuMu tools")
        case .HarmonyOS: return L10n.text("连接 DevEco Studio 的模拟器工具")
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(nsImage: AppBrand.icon).resizable().frame(width: 30, height: 30)
                        Text("SimLaunch").font(.title3.weight(.semibold))
                    }
                    Text(L10n.text("开发环境")).font(.subheadline).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.top, 10)
                VStack(spacing: 6) {
                    Button { selected = nil } label: {
                        HStack(spacing: 10) {
                            GeneralSettingsIcon(size: 25)
                            Text(L10n.text("General")).font(.system(size: 13, weight: .medium))
                            Spacer()
                        }.padding(.horizontal, 12).padding(.vertical, 11)
                            .foregroundStyle(selected == nil ? Color.accentColor : Color.primary)
                            .background(selected == nil ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider().padding(.vertical, 6)
                    ForEach(Platform.allCases) { platform in
                        Button {
                            selected = platform
                        } label: {
                            HStack(spacing: 10) {
                                PlatformIcon(platform: platform, size: 25)
                                Text(platform.rawValue).font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                Spacer()
                            }.padding(.horizontal, 12).padding(.vertical, 11)
                                .foregroundStyle(selected == platform ? Color.accentColor : Color.primary)
                                .background(selected == platform ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                Label(L10n.text("模拟器管理"), systemImage: "desktopcomputer")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            }.padding(16).frame(width: 210)
                .modifier(AdaptiveGlass(radius: 18)).padding(8)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    if let selected { PlatformIcon(platform: selected, size: 52) }
                    else { GeneralSettingsIcon(size: 52) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selected?.rawValue ?? L10n.text("General")).font(.system(size: 23, weight: .semibold))
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.bottom, 24)
                if selected == nil {
                    generalSettings
                } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 0) {
                            switch selected {
                            case nil: EmptyView()
                            case .iOS:
                                pathField(L10n.text("Xcode 开发者目录"), text: $draft.developerDir, placeholder: "/Applications/Xcode.app/Contents/Developer", hint: L10n.text("留空使用系统当前选择的 Xcode。"), directory: true)
                                Divider().padding(.horizontal, 18)
                                pathField(L10n.text("模拟器应用"), text: Binding(get: { draft.simulatorApp ?? "" }, set: { draft.simulatorApp = $0.isEmpty ? nil : $0 }), placeholder: L10n.text("Simulator.app 或 DeviceHub.app"), hint: L10n.text("自动兼容新版 Device Hub 与旧版 Simulator。"), application: true)
                            case .Android:
                                pathField("Emulator", text: $draft.emulator, placeholder: "…/Android/sdk/emulator/emulator", hint: L10n.text("选择 Android SDK 中的 emulator 可执行文件。"))
                                Divider().padding(.horizontal, 18)
                                pathField("ADB", text: $draft.adb, placeholder: "…/Android/sdk/platform-tools/adb", hint: L10n.text("自动优先使用与 Emulator 同一 SDK 的工具。"))
                                Divider().padding(.horizontal, 18)
                                pathField(L10n.text("虚拟设备目录"), text: $draft.avdHome, placeholder: "~/.android/avd", hint: L10n.text("仅在 AVD 存放位置经过修改时填写。"), directory: true)
                                Divider().padding(.horizontal, 18)
                                pathField("MuMu Tool", text: Binding(get: { draft.mumuTool ?? "" }, set: { draft.mumuTool = $0.isEmpty ? nil : $0 }), placeholder: "…/MuMuPlayer.app/Contents/MacOS/mumutool", hint: L10n.text("MuMu tool hint"))
                            case .HarmonyOS:
                                pathField("Emulator", text: $draft.harmony, placeholder: "…/DevEco-Studio.app/Contents/tools/emulator/Emulator", hint: L10n.text("选择 DevEco Studio 内的 Emulator 可执行文件。"))
                                Divider().padding(.horizontal, 18)
                                pathField("HDC", text: Binding(get: { draft.hdc ?? "" }, set: { draft.hdc = $0.isEmpty ? nil : $0 }), placeholder: "…/openharmony/toolchains/hdc", hint: L10n.text("HDC is used for live logs. Leave empty to discover it in the selected DevEco Studio SDK."))
                            }
                        }.modifier(AdaptiveCard())
                        Label {
                            Text(L10n.text("Leave paths empty for automatic discovery. Save path changes to apply them. Supports ~ and spaces."))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: { Image(systemName: "info.circle") }
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                        Button(L10n.text("Restore automatic discovery")) { resetSelected() }.buttonStyle(.link)
                            .disabled(selected.map { draft.usesAutomaticPaths(for: $0) } ?? true)
                            .help(L10n.text("Clear this platform’s manual paths, then save to apply."))
                    }.padding(.bottom, 12)
                }
                Divider().padding(.top, 12).padding(.bottom, 16)
                HStack {
                    Text(hasChanges ? L10n.text("有尚未保存的更改") : saved ? L10n.text("设置已保存") : L10n.text("设置仅对 SimLaunch 生效"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("保存并刷新")) {
                        do {
                            try draft.validateManualPaths()
                            store.config = draft
                            store.save()
                            saved = true
                        } catch { pathError = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!hasChanges)
                }.padding(10).modifier(AdaptiveGlass())
                }
            }.padding(24).frame(maxWidth: .infinity)
        }.frame(width: 880, height: 620)
            .background(Color(nsColor: .windowBackgroundColor))
            .modifier(AppAppearanceModifier())
            .environment(\.locale, Locale(identifier: language == "system" ? L10n.language : language))
            .background(SettingsWindowAttachment().frame(width: 0, height: 0))
            .navigationTitle(L10n.text("SimLaunch 设置"))
            .onAppear { draft = store.config; loginItem.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
            .alert(L10n.text("操作失败"), isPresented: Binding(get: { pathError != nil || loginItem.error != nil }, set: { if !$0 { pathError = nil; loginItem.error = nil } })) {
                Button(L10n.text("好")) { pathError = nil; loginItem.error = nil }
            } message: { Text(pathError ?? loginItem.error ?? "") }
    }

    private var generalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        Image(systemName: "power").font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("Launch at login")).font(.system(size: 13, weight: .semibold))
                            Text(L10n.text("Open SimLaunch when you sign in to your Mac."))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        Toggle(L10n.text("Launch at login"), isOn: Binding(get: { loginItem.requested }, set: { loginItem.setEnabled($0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(!loginItem.available || loginItem.updating)
                    }.padding(20)
                    if !loginItem.available {
                        Text(L10n.text("Configure this in the packaged SimLaunch.app."))
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 16)
                    } else if loginItem.status == .requiresApproval {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("Approval required in System Settings.")).font(.caption).foregroundStyle(.secondary)
                            Button(L10n.text("Open Login Items Settings")) { loginItem.openSystemSettings() }.buttonStyle(.link)
                        }.padding(.horizontal, 20).padding(.bottom, 16)
                    }
                    Divider().padding(.horizontal, 20)
                    HStack(spacing: 14) {
                        Image(systemName: "globe").font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("语言")).font(.system(size: 13, weight: .semibold))
                            Text(L10n.text("Choose the display language for SimLaunch."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Picker(L10n.text("语言"), selection: $language) {
                            Text(L10n.text("跟随系统")).tag("system")
                            Text("简体中文").tag("zh-Hans")
                            Text("English").tag("en")
                        }.labelsHidden().pickerStyle(.menu).frame(width: 140)
                    }.padding(20)
                    Divider().padding(.horizontal, 20)
                    HStack(spacing: 14) {
                        Image(systemName: "circle.lefthalf.filled").font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("外观")).font(.system(size: 13, weight: .semibold))
                            Text(L10n.text("Choose light, dark, or follow your Mac."))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        Picker(L10n.text("外观"), selection: $appearance) {
                            ForEach(AppAppearance.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 250)
                    }.padding(20)
                }.modifier(AdaptiveCard())
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("Software updates")).font(.system(size: 13, weight: .semibold))
                            Text("SimLaunch \(updates.version) (\(updates.build))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.text("Check for updates…")) { updates.checkForUpdates() }.disabled(!updates.canCheck)
                    }
                    if !updates.configured {
                        Text(L10n.text("In-app updates are available in configured release builds."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(L10n.text("View releases")) { updates.openReleases() }.buttonStyle(.link).font(.caption)
                }.padding(20)
                    .modifier(AdaptiveCard())
                Link(destination: AppBrand.websiteURL) {
                    HStack(spacing: 14) {
                        Image(systemName: "safari").font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("Official website")).font(.system(size: 13, weight: .semibold))
                            Text("echo-braveshine.github.io/SimLaunch")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 16)
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }.padding(20).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.primary)
                    .modifier(AdaptiveCard())
                    .help(AppBrand.websiteURL.absoluteString)
                    .accessibilityHint(L10n.text("Open the SimLaunch website in your default browser."))
                Link(destination: AppBrand.supportURL) {
                    HStack(spacing: 14) {
                        Image(systemName: "cup.and.saucer").font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("Buy me a coffee")).font(.system(size: 13, weight: .semibold))
                            Text(L10n.text("Optional support for ongoing development."))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }.padding(20).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.primary)
                    .modifier(AdaptiveCard())
                    .help(AppBrand.supportURL.absoluteString)
                    .accessibilityHint(L10n.text("Open Buy Me a Coffee in your default browser."))
            }.padding(.bottom, 4)
        }
    }

    private func pathField(_ title: String, text: Binding<String>, placeholder: String, hint: String, directory: Bool = false, application: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if text.wrappedValue.isEmpty {
                    Text(L10n.text("自动查找")).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .help(L10n.text("An empty path enables automatic discovery; it does not confirm that the tool is installed."))
                }
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: text).font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(title)
                Button {
                    let panel = NSOpenPanel()
                    panel.title = L10n.text("选择") + (L10n.language == "en" ? " " : "") + title
                    panel.canChooseDirectories = directory
                    panel.canChooseFiles = !directory
                    panel.allowsMultipleSelection = false
                    panel.prompt = L10n.text("选择")
                    panel.treatsFilePackagesAsDirectories = !application
                    if application { panel.allowedContentTypes = [.applicationBundle] }
                    panel.begin { response in
                        if response == .OK, let url = panel.url { text.wrappedValue = url.path }
                    }
                } label: { Image(systemName: "folder") }
                .help(L10n.text("选择") + (L10n.language == "en" ? " " : "") + title).accessibilityLabel(L10n.text("选择") + (L10n.language == "en" ? " " : "") + title)
            }
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18)
    }
    private func resetSelected() {
        guard let selected else { return }
        draft.useAutomaticPaths(for: selected)
        saved = false
    }
}
