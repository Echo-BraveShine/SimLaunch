import AppKit
import Combine
import SimLaunchCore
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor final class UpdateController: ObservableObject {
    static let shared = UpdateController()
    @Published private(set) var canCheck = false
    @Published private(set) var configured = false
    let releasesURL = URL(string: "https://github.com/Echo-BraveShine/SimLaunch/releases")!
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif
    private init() {
        #if canImport(Sparkle)
        guard Bundle.main.bundleURL.pathExtension == "app",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        configured = true
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        #endif
    }
    func checkForUpdates() {
        #if canImport(Sparkle)
        guard canCheck else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
        #endif
    }
    func openReleases() { NSWorkspace.shared.open(releasesURL) }
}
