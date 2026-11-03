import AppKit
import SwiftUI

/// Headless UI renders for review: `Whispr --snap-panes <dir>`. Draws every Home pane, every
/// onboarding step and the floating views in light and dark into PNGs. Panes render the real
/// local data (history, stats, meetings); only the PNGs are written. The mic and screen capture
/// are never started (`isRendering` keeps the onboarding level meter off).
@MainActor
enum Snapshot {
    nonisolated(unsafe) static var isRendering = false

    static func run(dir: String) {
        isRendering = true
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let state = AppState()
        state.status = "ready · small.en"
        let transcriber = Transcriber()
        let meetings = MeetingController(transcriber: transcriber)
        let importModel = FileImportModel(transcriber: transcriber)
        let onboarding = OnboardingModel()

        for (tag, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: name)
            app.appearance = appearance

            for pane in HomePane.allCases {
                state.pane = pane
                let view = HomeView(state: state, meetingController: meetings, importModel: importModel)
                write(view, size: NSSize(width: 960, height: 672), appearance: appearance,
                      to: out.appendingPathComponent("\(tag)-\(slug(pane.rawValue)).png"))
            }

            for step in 0...OnboardingModel.Step.done.rawValue {
                onboarding.step = OnboardingModel.Step(rawValue: step) ?? .welcome
                write(OnboardingView(model: onboarding), size: NSSize(width: 520, height: 560), appearance: appearance,
                      to: out.appendingPathComponent("\(tag)-onboarding-\(step)-\(String(describing: onboarding.step)).png"))
            }

            let pill = PillModel()
            pill.preview = "so the plan for Thursday is to ship the new"
            write(RecordingPill(model: pill, onCancel: {}, onStop: {}), size: nil, appearance: appearance,
                  to: out.appendingPathComponent("\(tag)-float-pill.png"))
            write(IdlePillView(onTap: {}, onHide: {}), size: nil, appearance: appearance,
                  to: out.appendingPathComponent("\(tag)-float-idle.png"))
            write(ToastView(pairs: [(from: "stratsy", to: "Stratzy")], onAdd: {}, onClose: {}).frame(width: 340),
                  size: nil, appearance: appearance, to: out.appendingPathComponent("\(tag)-float-toast.png"))
            write(PromptView(message: "Meeting detected in Zoom. Start recording?",
                             labels: ["Start", "Not now", "Always"], onPick: { _ in }).frame(width: 340),
                  size: nil, appearance: appearance, to: out.appendingPathComponent("\(tag)-float-prompt.png"))
        }
        print("snap-panes: wrote to \(out.path)")
    }

    private static func slug(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "-") }

    /// Host in an off-screen window, let SwiftUI settle, render at 2x.
    private static func write<V: View>(_ view: V, size: NSSize?, appearance: NSAppearance?, to url: URL) {
        let content: AnyView = size == nil
            ? AnyView(view.padding(20).background(Brand.bg))
            : AnyView(view)
        let host = NSHostingView(rootView: content)
        let s = size ?? host.fittingSize
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: s), styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = appearance
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: s)
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderFrontRegardless()
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
        }
        let bounds = host.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        win.orderOut(nil)
    }
}
