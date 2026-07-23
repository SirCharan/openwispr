import AppKit

// Renders the Whispr app icon (coral waveform on a dark squircle) and builds AppIcon.icns.
// Run: swift Tools/make_icon.swift   (writes Resources/AppIcon.icns)

let bg = NSColor(red: 0.039, green: 0.039, blue: 0.043, alpha: 1)   // #0a0a0b
let coral = NSColor(red: 1.0, green: 0.365, blue: 0.329, alpha: 1)  // #ff5d54
let heights: [CGFloat] = [0.26, 0.46, 0.68, 0.92, 0.68, 0.46, 0.26]

func drawIcon(_ px: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    NSBezierPath(roundedRect: rect, xRadius: px * 0.223, yRadius: px * 0.223).addClip()
    bg.setFill()
    rect.fill()

    let barW = px * 0.075
    let gap = px * 0.045
    let n = CGFloat(heights.count)
    let totalW = n * barW + (n - 1) * gap
    var x = (px - totalW) / 2
    coral.setFill()
    for h in heights {
        let barH = px * h * 0.62
        let y = (px - barH) / 2
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: barH),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

let fm = FileManager.default
let iconset = "build/Whispr.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try! png(drawIcon(px)).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

try? fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
