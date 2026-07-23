import Foundation

/// Thin UserDefaults-backed preferences. Exposed in the Settings UI at M5.
enum Settings {
    /// Auto-paste transcript at the cursor (Cmd+V). If false, text is left on the clipboard only.
    static var autoPaste: Bool {
        get { UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPaste") }
    }
}
