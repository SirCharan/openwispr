import AppKit
import SwiftUI

/// Hosts the SwiftUI SettingsView in a standard window, shown from the menu bar.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(currentModel: String, models: [String], onReloadModel: @escaping (String) -> Void) {
        if window == nil {
            let view = SettingsView(currentModel: currentModel, models: models, onReloadModel: onReloadModel)
            let hosting = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Whispr Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
