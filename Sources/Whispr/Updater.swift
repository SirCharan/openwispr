import AppKit
import Sparkle

/// Sparkle auto-update. The feed and EdDSA public key live in Info.plist.
@MainActor
final class Updater {
    static let shared = Updater()
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    var updater: SPUUpdater { controller.updater }
    func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// Headless probe for `--update-test <feedURL>`: asks Sparkle whether the feed has a newer build.
/// Prints `found <version>` / `no update` / `error <msg>`; exit code 1 only on error.
final class UpdateProbe: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    private var updater: SPUUpdater!
    private let feed: String
    init(feed: String) { self.feed = feed }

    func run() -> Never {
        // Registered (not persisted) defaults override Info.plist SUFeedURL, same path as `-SUFeedURL url` on the command line.
        UserDefaults.standard.register(defaults: ["SUFeedURL": feed])
        DispatchQueue.main.async { [self] in
            updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
            do { try updater.start() } catch { finish("error \(error.localizedDescription) \((error as NSError).userInfo) main=\(Thread.isMainThread)", 1) }
            updater.checkForUpdatesInBackground()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.finish("error timeout", 1) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
        exit(1)
    }

    private func finish(_ line: String, _ code: Int32) -> Never { print(line); exit(code) }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { finish("found \(item.displayVersionString)", 0) }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) { finish("no update", 0) }
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) { finish("error \(error.localizedDescription) \((error as NSError).userInfo) main=\(Thread.isMainThread)", 1) }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.dismiss) }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.dismiss) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}
