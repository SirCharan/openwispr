import AppKit

/// Muesli-style Dock behavior for a menu-bar app: the Dock icon (and Cmd-Tab entry)
/// appears while a real window is open and disappears when the last one closes.
@MainActor
enum DockPolicy {
    /// Call after showing or closing any main window.
    static func update() {
        let hasVisibleWindow = NSApp.windows.contains {
            $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled)
        }
        let want: NSApplication.ActivationPolicy = hasVisibleWindow ? .regular : .accessory
        if NSApp.activationPolicy() != want {
            NSApp.setActivationPolicy(want)
            if want == .regular { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
