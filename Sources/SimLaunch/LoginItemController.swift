import AppKit
import ServiceManagement
import SimLaunchCore

@MainActor final class LoginItemController: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var updating = false
    @Published var error: String?
    var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    var requested: Bool { status == .enabled || status == .requiresApproval }
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) {
        guard available, !updating else { return }
        updating = true
        defer { refresh(); updating = false }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { self.error = error.localizedDescription }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
