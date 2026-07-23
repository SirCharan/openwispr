import AppKit

/// Frontmost-app awareness for per-app enable/disable.
enum AppMonitor {
    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Regular (dock-visible) running apps as (name, bundleID), sorted, deduped.
    static func regularApps() -> [(name: String, id: String)] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return (name, id)
            }
        return Array(Dictionary(apps, uniquingKeysWith: { a, _ in a }).map { ($0.value, $0.key) })
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    static func name(for bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }
}
