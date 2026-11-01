import AppKit
import Foundation

@MainActor enum AppBrand {
    static let icon: NSImage = {
        guard let url = Bundle.module.url(forResource: "SimLaunchIcon", withExtension: "png"), let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing approved SimLaunch app icon")
        }
        return image
    }()
    static let menuBarIcon: NSImage = {
        guard let url = Bundle.module.url(forResource: "MenuBarTemplate", withExtension: "png"), let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing SimLaunch menu bar template")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}
