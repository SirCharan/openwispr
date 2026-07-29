import AppKit
import SwiftUI

/// Floating one-click "add to dictionary" prompt (Paper Studio chrome).
/// Non-activating, top-right under the menu bar, auto-dismisses after 10 s.
@MainActor
final class CorrectionToast {
    static let shared = CorrectionToast()
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    /// Show up to 3 spelling corrections; Add appends the corrected words to the dictionary vocab.
    func show(_ pairs: [(from: String, to: String)]) {
        guard !pairs.isEmpty else { return }
        hide()
        let shown = Array(pairs.prefix(3))
        let view = ToastView(
            pairs: shown,
            onAdd: { [weak self] in
                var d = DictionaryStore.load()
                for p in shown {
                    d.vocab.removeAll { $0.lowercased() == p.to.lowercased() }
                    d.vocab.append(p.to)
                }
                DictionaryStore.save(d)
                Stats.noteFixAccepted(shown.count) // Insights: "fixes you taught it"
                self?.hide()
            },
            onClose: { [weak self] in self?.hide() }
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: CGFloat(64 + shown.count * 24))
        let p = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 16, y: f.maxY - p.frame.height - 12))
        }
        p.orderFrontRegardless()
        panel = p
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        dismissTimer?.invalidate(); dismissTimer = nil
        panel?.orderOut(nil); panel = nil
    }
}

private struct ToastView: View {
    let pairs: [(from: String, to: String)]
    let onAdd: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Teach OpenWispr this spelling?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.text)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Brand.muted)
            }
            ForEach(pairs, id: \.to) { p in
                HStack(spacing: 6) {
                    Text(p.from).font(Brand.mono(12)).strikethrough().foregroundStyle(Brand.muted)
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Brand.muted)
                    Text(p.to).font(Brand.mono(12)).bold().foregroundStyle(Brand.coral)
                }
            }
            Button(action: onAdd) {
                Text("Add to dictionary")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Brand.coral))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Brand.bg)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line))
                .shadow(color: Brand.text.opacity(0.18), radius: 12, y: 4)
        )
    }
}
