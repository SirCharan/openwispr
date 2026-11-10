import ServiceManagement
import Foundation

/// Launch-at-login via the native SMAppService (macOS 13+). No third-party dependency.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    enum Action: Equatable { case none, register, hint }

    /// Pure decision: what to do at launch given the preference and the current SMAppService state.
    static func decide(wanted: Bool, enabled: Bool, requiresApproval: Bool) -> Action {
        if !wanted || enabled { return .none }
        return requiresApproval ? .hint : .register
    }

    /// Keeps "always" true: re-register at launch if the user hasn't opted out. Returns true when the approval hint is needed.
    @discardableResult
    static func ensure() -> Bool {
        let st = SMAppService.mainApp.status
        switch decide(wanted: Settings.launchAtLogin, enabled: st == .enabled, requiresApproval: st == .requiresApproval) {
        case .none: return false
        case .hint: return true
        case .register: _ = set(true); return SMAppService.mainApp.status == .requiresApproval
        }
    }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func selfTest() {
        assert(decide(wanted: true, enabled: false, requiresApproval: false) == .register)
        assert(decide(wanted: true, enabled: true, requiresApproval: false) == .none)
        assert(decide(wanted: false, enabled: false, requiresApproval: false) == .none)
        assert(decide(wanted: true, enabled: false, requiresApproval: true) == .hint)
        print("LoginItem.selfTest ok")
    }

    /// Returns true on success. `register()` throws when the app is ad-hoc-signed or not yet in
    /// /Applications — callers should revert their toggle + tell the user to move the app first.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            Settings.launchAtLogin = on
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("[Whispr] login-item toggle failed: \(error)")
            return false
        }
    }
}
