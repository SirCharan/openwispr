import AppKit

/// The modifier keys that can act as a hold-to-talk trigger (Muesli pattern):
/// captured via flagsChanged, which the shortcut recorder cannot do (Carbon needs key+modifier).
enum Triggers {
    struct Trigger {
        let id: String       // Settings.hotkeyMode value
        let label: String
        let keyCode: UInt16
        let flag: NSEvent.ModifierFlags
    }

    static let list: [Trigger] = [
        Trigger(id: "fn", label: "fn / 🌐", keyCode: 63, flag: .function),
        Trigger(id: "rcmd", label: "Right ⌘", keyCode: 54, flag: .command),
        Trigger(id: "lcmd", label: "Left ⌘", keyCode: 55, flag: .command),
        Trigger(id: "ropt", label: "Right ⌥", keyCode: 61, flag: .option),
        Trigger(id: "lopt", label: "Left ⌥", keyCode: 58, flag: .option),
        Trigger(id: "rctrl", label: "Right ⌃", keyCode: 62, flag: .control),
        Trigger(id: "lctrl", label: "Left ⌃", keyCode: 59, flag: .control),
        Trigger(id: "rshift", label: "Right ⇧", keyCode: 60, flag: .shift),
    ]

    static func trigger(for id: String) -> Trigger {
        list.first { $0.id == id } ?? list[0] // unknown id → fn
    }
}

/// Global single-modifier-key monitor for push-to-talk (fn, Right ⌘, Left ⌃, …) via flagsChanged.
/// Uses NSEvent global+local monitors — requires the Accessibility grant Whispr already needs
/// for paste. UI tip for fn: set System Settings → Keyboard → "Press 🌐 key to" = Do Nothing.
@MainActor
final class ModifierKeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyDownState = false

    init(trigger: Triggers.Trigger, onKeyDown: @escaping () -> Void, onKeyUp: @escaping () -> Void) {
        let handle: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == trigger.keyCode, let self else { return }
            let down = event.modifierFlags.contains(trigger.flag)
            if down && !self.keyDownState { self.keyDownState = true; onKeyDown() }
            else if !down && self.keyDownState { self.keyDownState = false; onKeyUp() }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in handle(e); return e }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
