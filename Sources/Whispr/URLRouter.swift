import AppKit

/// Handles `openwispr://…` (Info.plist CFBundleURLTypes) via the kAEGetURL Apple event.
/// Shortcuts "Open URL", the CLI and scripts all drive the running app through this.
/// Any web page can open these URLs too, so starting a recording or writing the dictionary asks
/// first unless the URL carries `t=<secret>` from a 0600 file only local processes can read (the CLI does).
@MainActor
final class URLRouter {
    enum Action: Equatable {
        case dictationStart, dictationStop, meetingStart, meetingStop
        case open(String)
        case dictionaryAdd(term: String, replace: String?)
        /// Opens the License pane with the key prefilled; never activates silently.
        case licenseActivate(key: String)
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
        let trusted = Self.tokenMatches(Self.token(in: s), Self.sharedToken())
        if Self.needsConfirm(a, trusted: trusted), !Self.confirm(a) {
            Log.app.notice("openwispr URL declined by user")
            return
        }
        handler(a)
    }

    /// Pure. Recording starts and dictionary writes from an untrusted URL need a yes from the user.
    nonisolated static func needsConfirm(_ a: Action, trusted: Bool) -> Bool {
        switch a {
        case .dictationStart, .meetingStart, .dictionaryAdd: return !trusted
        case .dictationStop, .meetingStop, .open, .licenseActivate: return false
        }
    }

    private static func confirm(_ a: Action) -> Bool {
        let alert = NSAlert()
        switch a {
        case .dictationStart: alert.messageText = "Start dictation?"
        case .meetingStart: alert.messageText = "Start recording a meeting?"
        case .dictionaryAdd(let term, let replace):
            alert.messageText = "Add to your dictionary?"
            let t = String(term.prefix(80)), r = replace.map { String($0.prefix(80)) }
            alert.informativeText = (r.map { "Replace \"\(t)\" with \"\($0)\"." } ?? "Add \"\(t)\".") + "\n\n"
        default: return true
        }
        alert.informativeText += "A link or another app asked OpenWispr to do this. Allow it only if you started it."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Allow")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Value of the `t` query item, if any.
    nonisolated static func token(in s: String) -> String? {
        URLComponents(string: s)?.queryItems?.first { $0.name == "t" }?.value
    }

    /// Constant-time compare; a missing or empty token never matches.
    nonisolated static func tokenMatches(_ got: String?, _ want: String?) -> Bool {
        guard let g = got.map({ Array($0.utf8) }), let w = want.map({ Array($0.utf8) }), !w.isEmpty, g.count == w.count else { return false }
        return zip(g, w).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    nonisolated static let tokenURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenWispr/url-token")

    /// Load the shared secret, creating it (0600, 32 random bytes) on first use by the app or the CLI.
    nonisolated static func sharedToken(at url: URL = tokenURL) -> String? {
        if let t = try? String(contentsOf: url, encoding: .utf8), t.count == 64 { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: url) // a short or corrupt file; a racing creator wins below
        guard fm.createFile(atPath: url.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        return (try? String(contentsOf: url, encoding: .utf8)).flatMap { $0.count == 64 ? $0 : nil }
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
        case ("dictionary", "add"):
            // No control characters (a newline in a replacement would press Return wherever text is pasted).
            let clean = { (v: String) in v.count <= 500 && !v.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
            guard let term = q("term"), !term.isEmpty, clean(term), q("replace").map(clean) ?? true else { return nil }
            return .dictionaryAdd(term: term, replace: q("replace"))
        case ("license", "activate"): return q("key").flatMap { $0.isEmpty || $0.count > 256 ? nil : .licenseActivate(key: $0) }
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
        precondition(parse("openwispr://license/activate?key=ABC-123") == .licenseActivate(key: "ABC-123"), "URLRouter license failed")
        precondition(parse("openwispr://license/activate") == nil, "URLRouter license no key failed")
        precondition(parse("openwispr://dictionary/add") == nil && parse("https://x.com/dictation/start") == nil
                     && parse("openwispr://bogus/x") == nil, "URLRouter rejection failed")
        // Injection: control characters and oversized values are refused; the token query item is ignored by parse.
        precondition(parse("openwispr://dictionary/add?term=ok&replace=rm%20-rf%20~%0A") == nil
                     && parse("openwispr://dictionary/add?term=a%0Db") == nil
                     && parse("openwispr://dictionary/add?term=" + String(repeating: "a", count: 501)) == nil
                     && parse("openwispr://license/activate?key=" + String(repeating: "k", count: 257)) == nil, "URLRouter injection guard failed")
        precondition(parse("openwispr://meeting/start?t=abc") == .meetingStart && token(in: "openwispr://meeting/start?t=abc") == "abc", "URLRouter token parse failed")
        // Confirmation: untrusted starts and dictionary writes ask; stops, panes and license prefill do not.
        for a in [Action.dictationStart, .meetingStart, .dictionaryAdd(term: "x", replace: nil)] {
            precondition(needsConfirm(a, trusted: false) && !needsConfirm(a, trusted: true), "URLRouter confirm \(a)")
        }
        for a in [Action.dictationStop, .meetingStop, .open("Meetings"), .licenseActivate(key: "k")] {
            precondition(!needsConfirm(a, trusted: false), "URLRouter no-confirm \(a)")
        }
        let secret = String(repeating: "ab", count: 32)
        precondition(tokenMatches(secret, secret) && !tokenMatches(nil, secret) && !tokenMatches("", "")
                     && !tokenMatches(secret.dropLast() + "c", secret) && !tokenMatches("ab", secret) && !tokenMatches(secret, nil), "URLRouter token compare failed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("url-token")
        let t1 = sharedToken(at: f), t2 = sharedToken(at: f)
        let perms = (try? FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int) ?? nil
        precondition(t1 != nil && t1 == t2 && t1?.count == 64 && perms == 0o600, "URLRouter shared token failed")
        print("URLRouter.selfTest PASS")
    }
}
