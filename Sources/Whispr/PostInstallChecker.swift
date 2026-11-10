import AppKit

/// Offers to move the app to /Applications when it is launched from a DMG or ~/Downloads.
enum PostInstallChecker {
    @MainActor private static var asked = false

    static func shouldOffer(path: String, home: String) -> Bool {
        path.hasPrefix("/Volumes/") || path.hasPrefix(home + "/Downloads/")
    }

    /// Once per session. Uses the same move as onboarding (ditto, strip quarantine, relaunch).
    @MainActor static func offerIfNeeded() {
        guard !asked, shouldOffer(path: Bundle.main.bundlePath, home: NSHomeDirectory()) else { return }
        asked = true
        let a = NSAlert()
        a.messageText = "Move OpenWispr to Applications?"
        a.informativeText = "Running from \(Bundle.main.bundlePath.hasPrefix("/Volumes") ? "the disk image" : "Downloads") can lose macOS permissions and block updates. OpenWispr will relaunch after the move."
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Not now")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { AppController.moveToApplicationsAndRelaunch() }
    }

    static func selfTest() {
        assert(shouldOffer(path: "/Volumes/OpenWispr/OpenWispr.app", home: "/Users/x"))
        assert(shouldOffer(path: "/Users/x/Downloads/OpenWispr.app", home: "/Users/x"))
        assert(!shouldOffer(path: "/Applications/OpenWispr.app", home: "/Users/x"))
        assert(!shouldOffer(path: "/Users/x/Documents/OpenWispr.app", home: "/Users/x"))
        print("PostInstallChecker.selfTest ok")
    }
}
