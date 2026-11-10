import AppKit

/// Handles `openwispr://…` (Info.plist CFBundleURLTypes) via the kAEGetURL Apple event.
/// Shortcuts "Open URL", the CLI and scripts all drive the running app through this.
@MainActor
final class URLRouter {
    enum Action: Equatable {
        case dictationStart, dictationStop, meetingStart, meetingStop
        case open(String)
        case dictionaryAdd(term: String, replace: String?)
    }

    var handler: (Action) -> Void = { _ in }

    init() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handle(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let a = Self.parse(s) else { Log.app.error("unrecognised openwispr URL"); return }
        handler(a)
    }

    nonisolated static func parse(_ s: String) -> Action? {
        guard let c = URLComponents(string: s), c.scheme == "openwispr", let host = c.host else { return nil }
        let path = c.path.split(separator: "/").map(String.init).first ?? ""
        let q = { (n: String) in c.queryItems?.first { $0.name == n }?.value }
        switch (host, path) {
        case ("dictation", "start"): return .dictationStart
        case ("dictation", "stop"): return .dictationStop
        case ("meeting", "start"): return .meetingStart
        case ("meeting", "stop"): return .meetingStop
        case ("open", let pane) where !pane.isEmpty: return .open(pane)
        case ("dictionary", "add"): return q("term").flatMap { $0.isEmpty ? nil : .dictionaryAdd(term: $0, replace: q("replace")) }
        default: return nil
        }
    }

    nonisolated static func selfTest() {
        precondition(parse("openwispr://dictation/start") == .dictationStart, "URLRouter dictation start failed")
        precondition(parse("openwispr://dictation/stop") == .dictationStop, "URLRouter dictation stop failed")
        precondition(parse("openwispr://meeting/start") == .meetingStart, "URLRouter meeting start failed")
        precondition(parse("openwispr://meeting/stop") == .meetingStop, "URLRouter meeting stop failed")
        precondition(parse("openwispr://open/Meetings") == .open("Meetings"), "URLRouter open failed")
        precondition(parse("openwispr://dictionary/add?term=Kubernetes&replace=k8s") == .dictionaryAdd(term: "Kubernetes", replace: "k8s"), "URLRouter dictionary failed")
        precondition(parse("openwispr://dictionary/add") == nil && parse("https://x.com/dictation/start") == nil
                     && parse("openwispr://bogus/x") == nil, "URLRouter rejection failed")
        print("URLRouter.selfTest PASS")
    }
}
