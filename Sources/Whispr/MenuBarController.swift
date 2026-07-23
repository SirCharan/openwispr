import AppKit

/// Owns the menu-bar status item and its menu.
/// M0: idle icon + status line + Quit. Recording state / model / settings wired in later milestones.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let statusMenuItem: NSMenuItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Whispr")
            button.image?.isTemplate = true
        }

        statusMenuItem = NSMenuItem(title: "Whispr — idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Whispr",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        statusItem.menu = menu
    }

    /// Update the status line shown at the top of the menu (used by later milestones).
    func setStatus(_ text: String) {
        statusMenuItem.title = "Whispr — \(text)"
    }
}
