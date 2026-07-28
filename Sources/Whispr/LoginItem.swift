import ServiceManagement
import Foundation

/// Launch-at-login via the native SMAppService (macOS 13+). No third-party dependency.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns true on success. `register()` throws when the app is ad-hoc-signed or not yet in
    /// /Applications — callers should revert their toggle + tell the user to move the app first.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("[Whispr] login-item toggle failed: \(error)")
            return false
        }
    }
}
