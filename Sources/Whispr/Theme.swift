import AppKit
import SwiftUI

/// Accent color + appearance handling (Muesli-style customization).
enum Theme {
    static let accents: [(name: String, hex: String)] = [
        ("Tape Red", "E2543E"), ("Coral", "FF5D54"), ("Blue", "4C8DFF"),
        ("Green", "34C77B"), ("Purple", "A06BFF"), ("Amber", "FFB340"),
    ]

    static var accentHex: String {
        get { UserDefaults.standard.string(forKey: "accentHex") ?? "E2543E" }
        set { UserDefaults.standard.set(newValue, forKey: "accentHex") }
    }

    static var accent: Color { Color(nsColor: nsAccent) }

    static var nsAccent: NSColor {
        let hex = accentHex
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        return NSColor(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1
        )
    }

    /// "system" | "light" | "dark"
    static var appearance: String {
        get { UserDefaults.standard.string(forKey: "appearance") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "appearance") }
    }

    /// Apply the stored appearance app-wide (windows follow NSApp.appearance).
    @MainActor
    static func apply() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Pill hidden until this date ("Hide 1 hour" from the pill's context menu).
    static var pillHiddenUntil: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "pillHiddenUntil")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "pillHiddenUntil") }
    }
}
