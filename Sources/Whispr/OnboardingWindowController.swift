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
        win.title = "Welcome to OpenWispr"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        // Content is fixed 520×560 in OnboardingView; give the chrome a little headroom.
        win.setContentSize(NSSize(width: 520, height: 560))
        win.contentMinSize = NSSize(width: 520, height: 560)
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)
        DockPolicy.update() // Dock icon while the wizard is open
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                DockPolicy.update()
            }
        }
    }

    func close() { window?.close(); window = nil }
}
