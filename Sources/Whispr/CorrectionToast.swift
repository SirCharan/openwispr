import AppKit
import SwiftUI

/// Floating one-click "add to dictionary" prompt (Paper Studio chrome).
/// Non-activating, top-right under the menu bar, auto-dismisses after 10 s.
@MainActor
final class CorrectionToast {
    static let shared = CorrectionToast()
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    /// Show up to 3 spelling corrections; Add stages them in the Dictionary pane for confirmation.
    func show(_ pairs: [(from: String, to: String)]) {
        guard !pairs.isEmpty else { return }
        hide()
        let shown = Array(pairs.prefix(3))
        let view = ToastView(
            pairs: shown,
            onAdd: { [weak self] in
                // Never write to dictionary.json here. An open Dictionary pane holds its own
                // in-memory copy and saves on every change, so a direct write from the toast
                // was silently reverted (and vice versa). The pane is the single writer.
                NotificationCenter.default.post(
                    name: .whisprStageVocab, object: nil,
                    userInfo: ["terms": shown.map(\.to)]
                )
                self?.hide()
            },
            onClose: { [weak self] in self?.hide() }
        )
        present(NSHostingView(rootView: view), size: NSSize(width: 340, height: CGFloat(64 + shown.count * 24)), ttl: 10)
    }

    /// Generic yes/no style prompt: a message plus one button per action (each action also closes it).
    func ask(_ message: String, actions: [(String, () -> Void)]) {
        hide()
        let view = PromptView(message: message, labels: actions.map(\.0)) { [weak self] i in
            actions[i].1()
            self?.hide()
        }
        present(NSHostingView(rootView: view), size: NSSize(width: 340, height: 92), ttl: 20)
    }

    private func present(_ host: NSView, size: NSSize, ttl: TimeInterval) {
        host.frame = NSRect(origin: .zero, size: size)
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
        dismissTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
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
                    .foregroundStyle(Brand.onAccent)
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

private struct PromptView: View {
    let message: String
    let labels: [String]
    let onPick: (Int) -> Void

    private func a11yLabel(_ label: String, _ i: Int) -> String {
        if label == "Start" { return "Meeting prompt: Start" }
        if label.hasPrefix("Always") { return "Always" }
        return label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.text)
            HStack(spacing: 6) {
                ForEach(labels.indices, id: \.self) { i in
                    Button { onPick(i) } label: {
                        Text(labels[i])
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(i == 0 ? Brand.onAccent : Brand.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(i == 0 ? Brand.coral : Brand.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a11yLabel(labels[i], i))
                    .accessibilityIdentifier(a11yLabel(labels[i], i))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Brand.bg)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line))
                .shadow(color: Brand.text.opacity(0.18), radius: 12, y: 4)
        )
    }
}
