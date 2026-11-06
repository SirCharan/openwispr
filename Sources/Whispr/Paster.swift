import AppKit

/// Places text on the clipboard and (optionally) synthesizes Cmd+V to paste at the cursor.
/// Auto-paste requires Accessibility permission; without it, only the clipboard is set.
@MainActor
enum Paster {
    private static let vKeyCode: CGKeyCode = 0x09 // ANSI 'V'
    /// Bumped per deliver; a scheduled clipboard restore aborts if a newer paste owns the clipboard.
    private static var generation = 0

    static func deliver(_ text: String, autoPaste: Bool) {
        generation += 1
        let gen = generation
        let pb = NSPasteboard.general
        // Snapshot every type on every item, not just the string, so images/files/rich text survive.
        let previous: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ownedCount = pb.changeCount // ours after the write; any later copy by the user bumps it
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

        if !previous.isEmpty {
            // 1.5s: slow targets (Electron, remote desktops) read the pasteboard late; 0.6s ate pastes
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // Restore only if nobody (a newer paste or the user's own copy) took the clipboard since.
                guard gen == generation, pb.changeCount == ownedCount else { return }
                pb.clearContents()
                pb.writeObjects(previous.map { types in
                    let item = NSPasteboardItem()
                    for (t, d) in types { item.setData(d, forType: t) }
                    return item
                })
            }
        }
    }
}
