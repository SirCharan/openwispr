import Foundation

/// Thin UserDefaults-backed preferences. Single source for keys used by @AppStorage bindings.
enum Settings {
    /// Auto-paste transcript at the cursor (Cmd+V). If false, text is left on the clipboard only.
    static var autoPaste: Bool {
        get { UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPaste") }
    }

    /// First-run onboarding completed. When false, the wizard shows on launch.
    static var onboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "onboarded") }
    }

    /// Play a short sound when recording starts/stops (useful when the pill is hidden).
    static var soundCues: Bool {
        get { UserDefaults.standard.object(forKey: "soundCues") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundCues") }
    }

    /// Bundle IDs of apps where Whispr dictation is disabled.
    static var disabledApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: "disabledApps") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "disabledApps") }
    }

    /// Dictation language: "auto" (detect) or a WhisperKit code ("en", "es", …).
    static var language: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }
    static var languageCode: String? { language == "auto" ? nil : language }

    /// Dictation trigger: "fn" (default, hold the fn/🌐 key) or "custom" (KeyboardShortcuts recorder).
    static var hotkeyMode: String {
        get { UserDefaults.standard.string(forKey: "hotkeyMode") ?? "fn" }
        set { UserDefaults.standard.set(newValue, forKey: "hotkeyMode") }
    }

    /// Hands-free: tap the hotkey to start, tap again to stop (instead of hold-to-talk).
    static var handsFree: Bool {
        get { UserDefaults.standard.bool(forKey: "handsFree") }
        set { UserDefaults.standard.set(newValue, forKey: "handsFree") }
    }

    /// Remove filler words (um/uh/er) from transcripts.
    static var removeFillers: Bool {
        get { UserDefaults.standard.object(forKey: "removeFillers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "removeFillers") }
    }

    /// Capitalize sentences + normalize spacing.
    static var cleanUp: Bool {
        get { UserDefaults.standard.object(forKey: "cleanUp") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cleanUp") }
    }

    static var textOptions: TextProcessor.Options {
        TextProcessor.Options(removeFillers: removeFillers, cleanUp: cleanUp)
    }

    /// AI rewrite applied after the text pipeline: "off", "clean", "formal", "concise".
    static var rewriteStyle: String {
        get { UserDefaults.standard.string(forKey: "rewriteStyle") ?? "off" }
        set { UserDefaults.standard.set(newValue, forKey: "rewriteStyle") }
    }
}
