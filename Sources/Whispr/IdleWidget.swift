import AppKit
import SwiftUI

/// The screen the user is working on: the one under the mouse pointer.
/// NSScreen.main follows the key window, which strands floating pills on the other
/// display in a multi-monitor setup.
@MainActor
enum ScreenPlacer {
    static var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

/// Small persistent floating pill (Wispr Flow-Bar idle state): reminds you OpenWispr is
/// listening for its trigger, and starts a dictation on click. Hidden while recording
/// (the recording pill takes its place) and via "Hide 1 hour" / the Settings toggle.
/// Follows the user across screens and Spaces.
@MainActor
final class IdleWidget {
    private var panel: NSPanel?
    private let onTap: () -> Void
    /// True between show() and hide(): whether the app wants the pill on screen.
    /// Space/display changes re-run show() only while this is set.
    private var wantsVisible = false

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        let reposition: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsVisible else { return }
                self.show()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: reposition)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reposition)
    }

    func show() {
        wantsVisible = true
        guard Settings.showIdleWidget, Date() >= Theme.pillHiddenUntil else { panel?.orderOut(nil); return }
        if panel == nil {
            let host = NSHostingView(rootView: IdlePillView(
                onTap: { [weak self] in self?.onTap() },
                onHide: { [weak self] in
                    Theme.pillHiddenUntil = Date().addingTimeInterval(3600)
                    self?.hide()
                }
            ))
            host.frame = NSRect(x: 0, y: 0, width: 64, height: 36)
            let p = NSPanel(contentRect: host.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false // SwiftUI shadow inside; panel shadow doubles it
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = host
            panel = p
        }
        if let p = panel, let screen = ScreenPlacer.activeScreen {
            // bottom-left corner: out of the reading line, clear of the (usually centered) Dock
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.minX + 16, y: f.minY + 16))
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        wantsVisible = false
        panel?.orderOut(nil)
    }
}

private struct IdlePillView: View {
    let onTap: () -> Void
    let onHide: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2.5) {
            bar(7, delay: 0.00)
            bar(13, delay: 0.12)
            bar(9, delay: 0.24)
            bar(13, delay: 0.36)
            bar(7, delay: 0.48)
        }
        .frame(width: 56, height: 28)
        .background(
            Capsule().fill(Brand.bg)
                .overlay(Capsule().stroke(hovering ? Brand.coral : Brand.line, lineWidth: 1))
                .shadow(color: Brand.text.opacity(hovering ? 0.25 : 0.15), radius: hovering ? 8 : 5, y: 2)
        )
        .scaleEffect(hovering ? 1.08 : 1.0)
        .animation(.spring(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { onTap() }
        .contextMenu {
            Button("Start dictation") { onTap() }
            Button("Paste last transcript") {
                if let last = HistoryStore.load().first {
                    Paster.deliver(last.text, autoPaste: Settings.autoPaste)
                }
            }
            Button("Hide for 1 hour") { onHide() }
        }
        .help("Click to dictate — or tap \(AppController.hotkeyHint) (tap again to stop; hold works too)")
        .padding(4)
    }

    private func bar(_ height: CGFloat, delay: Double) -> some View {
        Capsule()
            .fill(hovering ? Brand.coral : Brand.muted)
            .frame(width: 3, height: hovering ? height + 3 : height)
            .animation(.easeInOut(duration: 0.35).delay(delay), value: hovering)
    }
}
