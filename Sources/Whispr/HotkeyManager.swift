import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk dictation shortcut. Used only in "custom shortcut" trigger mode.
    static let dictate = Self("dictate", default: .init(.d, modifiers: [.command, .shift]))
}

/// Forwards the global hotkey's raw key-down / key-up events. The recording policy
/// (hold-to-talk vs hands-free toggle) is decided by AppController based on Settings.
@MainActor
final class HotkeyManager {
    init(onKeyDown: @escaping () -> Void, onKeyUp: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .dictate, action: onKeyDown)
        KeyboardShortcuts.onKeyUp(for: .dictate, action: onKeyUp)
    }
}
