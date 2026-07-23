import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk dictation shortcut. Default: ⌘⇧D. Rebindable in Settings (M5).
    static let dictate = Self("dictate", default: .init(.d, modifiers: [.command, .shift]))
}

/// Registers the global push-to-talk hotkey: hold to record, release to transcribe.
@MainActor
final class HotkeyManager {
    init(onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .dictate, action: onStart)
        KeyboardShortcuts.onKeyUp(for: .dictate, action: onStop)
    }
}
