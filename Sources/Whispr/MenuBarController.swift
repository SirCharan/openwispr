import AppKit

/// Owns the menu-bar status item and its menu: status line, Settings…, Quit,
/// plus a recording-state icon swap.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let statusMenuItem: NSMenuItem
    private let onSettings: () -> Void
    private let onMeeting: () -> Void
    private let onImport: () -> Void
    private let onOpen: () -> Void

    init(onSettings: @escaping () -> Void, onMeeting: @escaping () -> Void,
         onImport: @escaping () -> Void, onOpen: @escaping () -> Void) {
        self.onSettings = onSettings
        self.onMeeting = onMeeting
        self.onImport = onImport
        self.onOpen = onOpen
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenuItem = NSMenuItem(title: "Whispr — starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Whispr")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open Whispr", action: #selector(openMain), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        let meeting = NSMenuItem(title: "Record Meeting…", action: #selector(openMeeting), keyEquivalent: "m")
        meeting.target = self
        menu.addItem(meeting)
        let importItem = NSMenuItem(title: "Transcribe File…", action: #selector(openImport), keyEquivalent: "t")
        importItem.target = self
        menu.addItem(importItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Whispr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openSettings() { onSettings() }
    @objc private func openMeeting() { onMeeting() }
    @objc private func openImport() { onImport() }
    @objc private func openMain() { onOpen() }

    func setStatus(_ text: String) {
        statusMenuItem.title = "Whispr — \(text)"
    }

    func setRecording(_ on: Bool) {
        let symbol = on ? "mic.circle.fill" : "mic.circle"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Whispr")
        statusItem.button?.image?.isTemplate = !on
    }
}
