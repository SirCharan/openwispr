import ServiceManagement
import Foundation

/// Launch-at-login via the native SMAppService (macOS 13+). No third-party dependency.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[Whispr] login-item toggle failed: \(error)")
        }
    }
}
