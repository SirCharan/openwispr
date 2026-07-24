import AppKit

/// Global fn/🌐-key monitor for push-to-talk (keyCode 63 via flagsChanged).
/// Uses NSEvent global+local monitors — covered by the Accessibility grant Whispr
/// already needs for paste. Tip surfaced in UI: set System Settings → Keyboard →
/// "Press 🌐 key to" = Do Nothing, or the emoji picker fires too.
@MainActor
final class FnKeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fnDown = false

    init(onKeyDown: @escaping () -> Void, onKeyUp: @escaping () -> Void) {
        let handle: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 63, let self else { return } // 63 = fn
            let down = event.modifierFlags.contains(.function)
            if down && !self.fnDown { self.fnDown = true; onKeyDown() }
            else if !down && self.fnDown { self.fnDown = false; onKeyUp() }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in handle(e); return e }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
