import Foundation

/// Thin UserDefaults-backed preferences. Exposed in the Settings UI at M5.
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
}
