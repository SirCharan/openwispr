import SwiftUI
import AppKit

// "Paper Studio" design tokens. Light hex values match web/index.html; dark is the same paper at night.
// Every colour resolves per appearance, so call sites never branch on the colour scheme.
enum Brand {
    private static func dyn(_ light: Int, _ dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return ns(isDark ? dark : light)
        })
    }
    private static func ns(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // Palette: light | dark
    static let bg = dyn(0xF4EFE6, 0x1E1B17)
    static let surface = dyn(0xECE4D6, 0x27231E)
    static let line = dyn(0xDCD2C0, 0x3A342C)
    static let text = dyn(0x241F1A, 0xF1EAE0)
    static let muted = dyn(0x6B5F4E, 0xA79C8B)      // 5.4:1 on cream, 6:1 on dark paper
    /// Text/icons on accent or status fills.
    static let onAccent = dyn(0xFFFFFF, 0xFFFFFF)

    // Status: muted earth tones, readable as text and as fills on paper.
    static let ok = dyn(0x4A7A48, 0x8DB882)
    static let warn = dyn(0xA8681C, 0xD9A25A)
    static let danger = dyn(0xB03A28, 0xE07A68)
    static let info = dyn(0x44698A, 0x8FB0CC)

    /// Follows the user's accent choice (Theme); tape red-coral #E2543E is the default.
    static var coral: Color { Color(nsColor: Theme.nsAccent) }
    static var coralSoft: Color { coral.opacity(0.12) }

    // Type scale
    static var display: Font { serif(28) }
    static var title: Font { serif(20) }
    static var heading: Font { .system(size: 15, weight: .semibold) }
    static var body: Font { .system(size: 13) }
    static var caption: Font { .system(size: 11) }
    static var mono: Font { mono(12) }
    static func serif(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }

    // Spacing
    static let s4: CGFloat = 4, s8: CGFloat = 8, s12: CGFloat = 12
    static let s16: CGFloat = 16, s24: CGFloat = 24, s32: CGFloat = 32
    // Radii
    static let rSm: CGFloat = 6, rMd: CGFloat = 10, rLg: CGFloat = 14

    /// Resolves `bg` under both appearances; they must differ or dark mode is silently broken.
    @MainActor
    static func selfTest() {
        func resolve(_ name: NSAppearance.Name) -> NSColor {
            var out = NSColor.clear
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                out = NSColor(Brand.bg).usingColorSpace(.sRGB) ?? .clear
            }
            return out
        }
        let dark = resolve(.darkAqua), light = resolve(.aqua)
        precondition(dark != light, "Brand.selfTest: bg identical in light and dark")
        precondition(abs(light.redComponent - 0xF4 / 255.0) < 0.01, "Brand.selfTest: light bg changed")
        precondition(abs(dark.redComponent - 0x1E / 255.0) < 0.01, "Brand.selfTest: dark bg wrong")
        print("Brand.selfTest PASS (bg light \(light.hexString) / dark \(dark.hexString))")
    }
}

private extension NSColor {
    var hexString: String {
        String(format: "#%02X%02X%02X", Int(round(redComponent * 255)), Int(round(greenComponent * 255)), Int(round(blueComponent * 255)))
    }
}
