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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Own one status item and one anchored device popover; settings are the only separate window.
@MainActor final class MenuBarController: NSObject {
    private let store: Store
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var preferencesObserver: NSObjectProtocol?
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
        popover.contentViewController = NSHostingController(rootView:
            Panel(openSettings: { [weak self] in self?.showSettings() }).environmentObject(store))
        configureMenus()
        applyAppearance()
        preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.applyAppearance()
                self?.settingsWindow?.title = L10n.text("SimLaunch 设置")
                if self?.menuLanguage != L10n.language { self?.configureMenus() }
            }
        }
    }

    @objc private func toggleDevices() {
        if popover.isShown { popover.close() }
        else { showDevices() }
    }

    func showDevices(remainingAttempts: Int = 10) {
        guard !popover.isShown else { return }
        guard let button = statusItem.button, button.window != nil else {
            if remainingAttempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.showDevices(remainingAttempts: remainingAttempts - 1) }
            }
            return
        }
        applyAppearance()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        applyAppearance()
        popover.contentViewController?.view.window?.makeKey()

    }

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
