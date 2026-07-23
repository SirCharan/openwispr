import AppKit
import ApplicationServices

/// Accessibility permission is required to synthesize Cmd+V (auto-paste).
/// Microphone permission is requested implicitly by AVAudioEngine on first record.
enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Prompt for Accessibility access (shows the system dialog + adds Whispr to the list).
    @discardableResult
    static func requestAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Open the Accessibility pane of System Settings.
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
