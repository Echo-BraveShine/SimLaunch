import AppKit
import SwiftUI
import SimLaunchCore

@MainActor final class SimLaunchAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppBrand.icon
        controller = MenuBarController(store: Store())
        controller?.showDevices()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showDevices()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller?.shutdownLogs({ sender.reply(toApplicationShouldTerminate: true) }) == true { return .terminateLater }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Own one status item and one anchored device popover; settings and device logs use independent windows.
@MainActor final class MenuBarController: NSObject {
    private let store: Store
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let panelHost = NSHostingController(rootView: AnyView(EmptyView()))
    private var listHeight: CGFloat = 480
    private var settingsWindow: NSWindow?
    private lazy var logWindows = LogWindowManager(store: store)
    private lazy var informationWindows = DeviceInformationWindowManager(store: store)
    private var preferencesObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var menuLanguage = ""

    init(store: Store) {
        self.store = store
        super.init()
        if let button = statusItem.button {
            button.image = AppBrand.menuBarIcon
            button.imagePosition = .imageOnly
            button.toolTip = "SimLaunch"
            button.target = self
            button.action = #selector(toggleDevices)
        }
        popover.behavior = .transient
        popover.animates = false
        updatePanel()
        popover.contentViewController = panelHost
        configureMenus()
        applyAppearance()
        // A context menu handing focus to Finder can leave AppKit's transient
        // popover tracking suspended. Also dismiss when our app deactivates.
        deactivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.popover.close() }
        }
        preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.applyAppearance()
                self?.settingsWindow?.title = L10n.text("SimLaunch 设置")
                self?.logWindows.refreshAppearanceAndTitles()
                self?.informationWindows.updateTitles()
                if self?.menuLanguage != L10n.language { self?.configureMenus() }
            }
        }
    }

    @objc private func toggleDevices() {
        if popover.isShown { popover.close() }
        else { showDevices() }
    }

    func showDevices(remainingAttempts: Int = 20) {
        guard !popover.isShown else { return }
        // The status item's window exists before the menu bar gives it a real frame.
        // Waiting only for a non-nil window can anchor the launch popover at (0, 0).
        guard let button = statusItem.button, let window = button.window,
              window.frame.height > 0, let screen = window.screen,
              screen.frame.intersects(window.frame) else {
            if remainingAttempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.showDevices(remainingAttempts: remainingAttempts - 1) }
            }
            return
        }
        applyAppearance()
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        // Anchor below the entire menu bar, rather than the inset icon button.
        // Use this window's screen so secondary displays and scaled screens work too.
        let top = min(buttonFrame.minY, window.frame.minY, screen.visibleFrame.maxY) - 6
        let distance = buttonFrame.minY - top
        let anchor = button.bounds.offsetBy(dx: 0, dy: button.isFlipped ? distance : -distance)
        let panelChrome = panelHost.view.fittingSize.height - listHeight
        let availableHeight = top - screen.visibleFrame.minY - 30 // Reserve the popover frame and arrow.
        let height = max(0, min(480, availableHeight - panelChrome))
        if height != listHeight {
            listHeight = height
            updatePanel()
        }
        popover.contentSize = panelHost.view.fittingSize
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        applyAppearance()
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updatePanel() {
        panelHost.rootView = AnyView(Panel(openSettings: { [weak self] in self?.showSettings() }, openLogs: { [weak self] device in self?.showLogs(device) }, openInformation: { [weak self] device in self?.popover.close(); self?.informationWindows.show(device) }, revealInFinder: { [weak self] device in self?.revealInFinder(device) }, listHeight: listHeight).environmentObject(store))
    }

    private func revealInFinder(_ device: Device) {
        guard let directory = device.directory, FileManager.default.fileExists(atPath: directory) else {
            store.showInFinder(device) // Keep validation errors visible in the panel.
            return
        }
        popover.close()
        // Let the context menu finish tracking before activating another app.
        DispatchQueue.main.async { [weak self] in self?.store.showInFinder(device) }
    }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }

    private func showLogs(_ device: Device) {
        popover.close()
        logWindows.show(device)
    }

    func shutdownLogs(_ completion: @escaping () -> Void) -> Bool { informationWindows.closeAll(); return logWindows.shutdown(completion) }

    @objc private func showSettings() {
        popover.close()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(store))
            window.setContentSize(NSSize(width: 880, height: 620))
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.initialFirstResponder = nil
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = L10n.text("SimLaunch 设置")
        applyAppearance()
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        SettingsWindowPresenter.shared.requestFocus()
    }

    private func applyAppearance() {
        (AppAppearance(rawValue: UserDefaults.standard.string(forKey: AppAppearance.storageKey) ?? "") ?? .system).apply()
        // Status item anchors inherit the menu bar's appearance, so override the popover too.
        popover.appearance = NSApp.appearance
        popover.contentViewController?.view.appearance = NSApp.appearance
        popover.contentViewController?.view.window?.appearance = NSApp.appearance
        settingsWindow?.appearance = NSApp.appearance
    }

    private func configureMenus() {
        menuLanguage = L10n.language
        let menu = NSMenu()
        let appMenu = NSMenu(title: "SimLaunch")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        let settings = appMenu.addItem(withTitle: L10n.text("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: L10n.text("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        let editMenu = NSMenu(title: L10n.text("Edit"))
        let editItem = NSMenuItem(); editItem.submenu = editMenu; menu.addItem(editItem)
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: L10n.text(title), action: Selector(action), keyEquivalent: key)
        }
        let windowMenu = NSMenu(title: L10n.text("Window"))
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; menu.addItem(windowItem)
        windowMenu.addItem(withTitle: L10n.text("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }
}

struct DeviceGroup<Content: View>: View {
    let title: String
    let count: Int
    private let content: Content
    @AppStorage private var expanded: Bool
    init(id: String, title: String, count: Int, initiallyExpanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title; self.count = count; self.content = content()
        _expanded = AppStorage(wrappedValue: initiallyExpanded, "sectionExpanded." + id)
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) { content }.padding(.top, 6)
        } label: {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(String(count)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
