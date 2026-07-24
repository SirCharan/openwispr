import AppKit

/// Places text on the clipboard and (optionally) synthesizes Cmd+V to paste at the cursor.
/// Auto-paste requires Accessibility permission; without it, only the clipboard is set.
enum Paster {
    private static let vKeyCode: CGKeyCode = 0x09 // ANSI 'V'

    static func deliver(_ text: String, autoPaste: Bool) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string) // restore after paste — don't eat the user's clipboard
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard autoPaste, Permissions.hasAccessibility else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
    }
}
