import SwiftUI
import AppKit

extension Notification.Name {
    /// Open the License pane. `userInfo["key"]` (String) prefills the key field; never activates by itself.
    static let whisprOpenLicense = Notification.Name("whispr.openLicense")
}

/// Observable face of `License`: current state, activate/deactivate, due-validation. Keychain stays the source of truth.
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()
    static let buyURL = URL(string: "https://openwispr.vercel.app/#pricing")!

    @Published private(set) var state: LicenseState = .trial(daysLeft: License.trialDays)
    @Published var busy = false
    @Published var error: String?
    private var preview: LicenseState?

    var daysLeftText: String? {
        switch state {
        case .trial(let d), .grace(let d): "\(d) day\(d == 1 ? "" : "s") left"
        default: nil
        }
    }

    func refresh() {
        state = preview ?? License.state(now: Date(), stored: License.load())
    }

    /// Snapshot/sample mode: show a fake state without touching the Keychain.
    func setPreview(_ tag: String) { preview = LicenseState(tag: tag); refresh() }

    /// Gate at start, never at delivery: nothing is recorded and then withheld.
    func allows(_ action: LicenseAction) -> Bool {
        refresh()
        return License.allows(action, in: state)
    }

    /// Returns true when allowed; otherwise tells the user and opens the License pane.
    func gate(_ action: LicenseAction) -> Bool {
        if allows(action) { return true }
        let msg = state == .trialExpired ? "Trial ended — buy to keep dictating" : "License needs attention to keep dictating"
        CorrectionToast.shared.ask(msg, actions: [("Open License", { Self.openPane() })])
        Self.openPane()
        return false
    }

    static func openPane(key: String? = nil) {
        NotificationCenter.default.post(name: .whisprOpenLicense, object: nil, userInfo: key.map { ["key": $0] })
    }

    /// First launch after onboarding starts the trial clock (idempotent), then validates if due.
    func launch() {
        License.apply(.launch)
        refresh()
        validateIfDue()
    }

    func startTrial() { License.apply(.launch); refresh() }

    func validateIfDue() {
        let stored = License.load()
        guard let l = stored.license, License.validateDue(now: Date(), stored: stored) else { return }
        Task {
            switch await LicenseClient.validate(key: l.key, instanceId: l.instanceId) {
            case .success(let ok): License.apply(.validated(valid: ok))
            case .failure(let e): License.apply(.failed(e))
            }
            refresh()
        }
    }

    func activate(key: String) async {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        busy = true; error = nil
        defer { busy = false; refresh() }
        switch await LicenseClient.activate(key: k) {
        case .success(let id): License.apply(.activated(key: k, instanceId: id))
        case .failure(let e): error = e.message; License.apply(.failed(e))
        }
    }

    func deactivate() async {
        guard let l = License.load().license else { return }
        busy = true; error = nil
        defer { busy = false; refresh() }
        if let e = await LicenseClient.deactivate(key: l.key, instanceId: l.instanceId) {
            error = e == .network ? "Connect to the internet to deactivate this Mac." : e.message
            return
        }
        License.apply(.deactivated)
    }
}

extension LicenseState {
    var headline: String {
        switch self {
        case .trial(let d): "Free trial · \(d) day\(d == 1 ? "" : "s") left"
        case .trialExpired: "Trial ended"
        case .active: "Licensed"
        case .grace: "Licensed · confirm online soon"
        case .lapsed: "Connect to the internet once to confirm your license."
        case .revoked: "This key has been disabled (refund or chargeback)."
        case .invalid: "That key isn't recognised. Check the email from Dodo Payments."
        }
    }
    var isOK: Bool { if case .active = self { true } else if case .trial = self { true } else if case .grace = self { true } else { false } }
}

struct BuyCard: View {
    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: Brand.s8) {
                Text("OpenWispr · $49 once").font(Brand.heading).foregroundStyle(Brand.text)
                Text("Lifetime updates, up to 3 Macs. The source stays MIT on GitHub; the signed build needs a license.")
                    .font(Brand.body).foregroundStyle(Brand.muted).fixedSize(horizontal: false, vertical: true)
                PaperButton(title: "Buy a license", role: .primary) { NSWorkspace.shared.open(LicenseManager.buyURL) }
            }
        }
    }
}

struct TrialBanner: View {
    @ObservedObject var license: LicenseManager
    var body: some View {
        if !(license.state == .active) {
            HStack(spacing: Brand.s12) {
                Image(systemName: license.state.isOK ? "clock" : "exclamationmark.triangle.fill")
                    .foregroundStyle(license.state.isOK ? Brand.muted : Brand.warn)
                Text(license.state.headline).font(Brand.body).foregroundStyle(Brand.text).lineLimit(2)
                Spacer(minLength: 8)
                PaperButton(title: "Buy $49", role: .primary) { NSWorkspace.shared.open(LicenseManager.buyURL) }
                PaperButton(title: "Enter key") { LicenseManager.openPane() }
            }
            .padding(.horizontal, Brand.s16).padding(.vertical, Brand.s8)
            .background(Brand.coralSoft)
            .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
        }
    }
}

/// Key field + Activate, reused by the pane and the onboarding step.
struct LicenseKeyField: View {
    @ObservedObject var license: LicenseManager
    @Binding var key: String
    var body: some View {
        VStack(alignment: .leading, spacing: Brand.s8) {
            HStack(spacing: Brand.s8) {
                TextField("License key", text: $key).textFieldStyle(.roundedBorder).font(Brand.mono)
                PaperButton(title: license.busy ? "Activating…" : "Activate", role: .primary) {
                    Task { await license.activate(key: key) }
                }.disabled(license.busy || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let e = license.error { Text(e).font(Brand.caption).foregroundStyle(Brand.danger).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct LicensePane: View {
    @ObservedObject var license = LicenseManager.shared
    @State private var key = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.s16) {
                Text("License").font(Brand.display).foregroundStyle(Brand.text)
                PaperCard {
                    HStack(spacing: Brand.s12) {
                        Image(systemName: license.state.isOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 22)).foregroundStyle(license.state.isOK ? Brand.ok : Brand.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(license.state.headline).font(Brand.heading).foregroundStyle(Brand.text)
                            if let d = license.daysLeftText { Text(d).font(Brand.caption).foregroundStyle(Brand.muted) }
                        }
                        Spacer()
                    }
                }
                if license.state == .active || { if case .grace = license.state { true } else { false } }() {
                    PaperCard {
                        VStack(alignment: .leading, spacing: Brand.s8) {
                            Text("This Mac is activated. Deactivate it to free a seat for another Mac.")
                                .font(Brand.body).foregroundStyle(Brand.muted)
                            PaperButton(title: license.busy ? "Deactivating…" : "Deactivate this Mac", role: .destructive) {
                                Task { await license.deactivate() }
                            }.disabled(license.busy)
                            if let e = license.error { Text(e).font(Brand.caption).foregroundStyle(Brand.danger) }
                        }
                    }
                } else {
                    BuyCard()
                    PaperSection(title: "Have a key?") { LicenseKeyField(license: license, key: $key) }
                }
            }
            .padding(Brand.s24).frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.bg)
        .onAppear {
            license.refresh()
            if let k = Self.pendingKey { key = k; Self.pendingKey = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .whisprOpenLicense)) { n in
            if let k = n.userInfo?["key"] as? String { key = k; Self.pendingKey = nil }
        }
    }

    /// Key from `openwispr://license/activate?key=` that arrived before the pane existed.
    nonisolated(unsafe) static var pendingKey: String?
}
