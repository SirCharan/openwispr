import AppKit
import SwiftUI
import Security

/// "What's new" sheet: shows the CHANGELOG section for the running version once per version.
enum WhatsNew {
    struct Decision: Equatable { var show: Bool; var regrant: Bool }

    /// Pure: show on a changed version (never on a fresh install); add the re-grant note when
    /// the signer changed from self-signed to Developer ID.
    static func decide(version: String, lastSeen: String?, signer: String, lastSigner: String?) -> Decision {
        guard let lastSeen, !lastSeen.isEmpty else { return Decision(show: false, regrant: false) }
        return Decision(show: lastSeen != version, regrant: signer == "developerID" && lastSigner == "selfSigned")
    }

    /// Body of the `## <version>` section (heading dropped), nil when absent.
    static func section(_ version: String, in changelog: String) -> String? {
        var out: [Substring] = []
        var inside = false
        for line in changelog.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if inside { break }
                let head = line.dropFirst(3).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                inside = head == version || head.hasPrefix(version + " ")
                continue
            }
            if inside { out.append(line) }
        }
        let text = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    /// "developerID" when the signature carries a Team ID, else "selfSigned".
    static var signerKind: String {
        var code: SecCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any], d[kSecCodeInfoTeamIdentifier as String] != nil else { return "selfSigned" }
        return "developerID"
    }

    static func changelogText() -> String? {
        Bundle.main.url(forResource: "CHANGELOG", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    @MainActor private static var window: NSWindow?

    /// Call on launch after onboarding. Records the version either way.
    @MainActor static func maybeShow() {
        let d = decide(version: version, lastSeen: Settings.lastSeenVersion, signer: signerKind, lastSigner: Settings.lastSignerKind)
        Settings.lastSeenVersion = version
        Settings.lastSignerKind = signerKind
        guard d.show, let body = changelogText().flatMap({ section(version, in: $0) }) else { return }
        let hosting = NSHostingController(rootView: WhatsNewView(version: version, notes: body, regrant: d.regrant, onClose: { window?.close() }))
        let win = NSWindow(contentViewController: hosting)
        win.title = "What's new in OpenWispr"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 520, height: 520))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = win
    }

    static func selfTest() {
        assert(decide(version: "0.20.0", lastSeen: nil, signer: "selfSigned", lastSigner: nil) == Decision(show: false, regrant: false))
        assert(decide(version: "0.20.0", lastSeen: "0.19.1", signer: "selfSigned", lastSigner: "selfSigned") == Decision(show: true, regrant: false))
        assert(decide(version: "0.20.1", lastSeen: "0.20.0", signer: "developerID", lastSigner: "selfSigned") == Decision(show: true, regrant: true))
        assert(decide(version: "0.20.1", lastSeen: "0.20.1", signer: "developerID", lastSigner: "developerID") == Decision(show: false, regrant: false))
        let log = "# Changelog\n\n## 0.20.0 (unreleased)\n- a\n- b\n\n## [0.19.1] - 2026-11-04\nOn-device.\n- c\n\n## 0.19.0\n- d\n"
        assert(section("0.20.0", in: log) == "- a\n- b")
        assert(section("0.19.1", in: log) == "On-device.\n- c".replacingOccurrences(of: "On-device.", with: "On-device."))
        assert(section("0.19.0", in: log) == "- d")
        assert(section("0.18.0", in: log) == nil)
        print("WhatsNew.selfTest ok")
    }
}

struct WhatsNewView: View {
    let version: String
    let notes: String
    var regrant = false
    var onClose: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: Brand.s16) {
            Text("What's new in \(version)").font(Brand.title).foregroundStyle(Brand.text)
            if regrant {
                Text("This build is signed with a Developer ID. macOS will ask you to re-allow Microphone, Accessibility and Screen Recording once.")
                    .font(Brand.body).foregroundStyle(Brand.text)
                    .padding(Brand.s12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.coralSoft, in: RoundedRectangle(cornerRadius: Brand.rSm))
            }
            ScrollView {
                Text(LocalizedStringKey(notes)).font(Brand.body).foregroundStyle(Brand.text)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            HStack { Spacer(); PaperButton(title: "Got it", role: .primary, action: onClose) }
        }
        .padding(Brand.s24).frame(width: 520, height: 520).background(Brand.bg)
    }
}
