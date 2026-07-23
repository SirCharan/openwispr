import AppKit
import SwiftUI

/// Hosts the first-run wizard in a centered window.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let model: OnboardingModel

    init(model: OnboardingModel) { self.model = model }

    func show() {
        let hosting = NSHostingController(rootView: OnboardingView(model: model))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Welcome to Whispr"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close(); window = nil }
}
