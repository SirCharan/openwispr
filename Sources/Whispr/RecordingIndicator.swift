import AppKit
import SwiftUI

/// Floating pill shown while recording: animated waveform + cancel (✕) and stop (■).
/// A non-activating panel so it never steals focus from the app you're dictating into.
@MainActor
final class RecordingIndicator {
    private var panel: NSPanel?

    func show(onCancel: @escaping () -> Void, onStop: @escaping () -> Void) {
        if panel == nil {
            let host = NSHostingView(rootView: RecordingPill(onCancel: onCancel, onStop: onStop))
            host.frame = NSRect(x: 0, y: 0, width: 176, height: 56)
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
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onCancel) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
            WaveBars()
            Button(action: onStop) { Image(systemName: "stop.fill") }
                .buttonStyle(.plain)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            Capsule().fill(Color(red: 0.08, green: 0.08, blue: 0.094))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        )
    }
}

private struct WaveBars: View {
    @State private var animate = false
    private let peaks: [CGFloat] = [12, 22, 16, 26, 18, 10]
    private let coral = Color(red: 1.0, green: 0.365, blue: 0.329)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(peaks.indices, id: \.self) { i in
                Capsule()
                    .fill(coral)
                    .frame(width: 4, height: animate ? peaks[i] : 5)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.08), value: animate)
            }
        }
        .frame(height: 28)
        .onAppear { animate = true }
    }
}
