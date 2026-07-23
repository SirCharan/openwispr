import AppKit
import SwiftUI

/// Live-preview text shown inside the pill while speaking.
@MainActor
final class PillModel: ObservableObject {
    @Published var preview = ""
}

/// Floating pill shown while recording: animated waveform + cancel (✕) and stop (■).
/// A non-activating panel so it never steals focus from the app you're dictating into.
@MainActor
final class RecordingIndicator {
    private var panel: NSPanel?
    let model = PillModel()

    func show(onCancel: @escaping () -> Void, onStop: @escaping () -> Void) {
        guard Date() >= Theme.pillHiddenUntil else { return } // user chose "Hide 1 hour"
        model.preview = ""
        if panel == nil {
            let host = NSHostingView(rootView: RecordingPill(model: model, onCancel: onCancel, onStop: onStop))
            host.frame = NSRect(x: 0, y: 0, width: 380, height: 76)
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
            panel = p
        }
        positionBottomCenter()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func positionBottomCenter() {
        guard let p = panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 90))
    }
}

private struct RecordingPill: View {
    @ObservedObject var model: PillModel
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button(action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                WaveBars()
                Button(action: onStop) { Image(systemName: "stop.fill") }
                    .buttonStyle(.plain)
            }
            if !model.preview.isEmpty {
                Text(model.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 320)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            Capsule().fill(Color(red: 0.08, green: 0.08, blue: 0.094))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        )
        .fixedSize()
        .contextMenu {
            Button("Paste last transcript") {
                if let last = HistoryStore.load().first {
                    Paster.deliver(last.text, autoPaste: Settings.autoPaste)
                }
            }
            Button("Hide pill for 1 hour") {
                Theme.pillHiddenUntil = Date().addingTimeInterval(3600)
            }
        }
    }
}

private struct WaveBars: View {
    @State private var animate = false
    private let peaks: [CGFloat] = [12, 22, 16, 26, 18, 10]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(peaks.indices, id: \.self) { i in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 4, height: animate ? peaks[i] : 5)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.08), value: animate)
            }
        }
        .frame(height: 28)
        .onAppear { animate = true }
    }
}
