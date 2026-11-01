import AppKit
import SwiftUI

/// Wait for SwiftUI to attach the window before activating it. Also handles reopening
/// an existing settings window, where onAppear is not called again.
@MainActor final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()
    private weak var window: NSWindow?
    private var focusRequested = false
    private var activationObserver: NSObjectProtocol?

    private init() {
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.focusIfReady() }
        }
    }

    func requestFocus() {
        focusRequested = true
        DispatchQueue.main.async { [weak self] in self?.focusIfReady() }
    }

    func attach(_ window: NSWindow) {
        self.window = window
        DispatchQueue.main.async { [weak self] in self?.focusIfReady() }
    }

    private func focusIfReady() {
        guard focusRequested, let window else { return }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            return // Complete the focus transfer after application activation finishes.
        }
        focusRequested = false
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(nil)
    }
}

struct SettingsWindowAttachment: NSViewRepresentable {
    final class AttachmentView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.initialFirstResponder = nil
                SettingsWindowPresenter.shared.attach(window)
                DispatchQueue.main.async { [weak window] in window?.makeFirstResponder(nil) }
            }
        }
    }
    func makeNSView(context: Context) -> AttachmentView { AttachmentView() }
    func updateNSView(_ nsView: AttachmentView, context: Context) {}
}

@MainActor final class WeakWindowReference {
    weak var window: NSWindow?
}

/// Capture only the window hosting this panel, never infer it from NSApp.keyWindow.
struct PanelWindowAttachment: NSViewRepresentable {
    let reference: WeakWindowReference
    final class AttachmentView: NSView {
        var reference: WeakWindowReference?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }
    }
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.reference = reference
        return view
    }
    func updateNSView(_ nsView: AttachmentView, context: Context) {
        reference.window = nsView.window
    }
}
