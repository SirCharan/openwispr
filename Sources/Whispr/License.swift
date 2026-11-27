import Foundation

/// A Dodo Payments license activated on this Mac. Stored as JSON in the Keychain.
struct License: Codable, Equatable {
    var key: String
    var instanceId: String
    var activatedAt: Date
    var lastValidatedAt: Date
    /// Set after a 403 / `valid:false`; the key stays on disk so the pane can say why.
    var revoked = false
    /// Last validation could not reach the server; drives grace → lapsed.
    var offline = false
}

enum LicenseState: Equatable {
    /// `unlicensed`: no key on this Mac. There is no trial; a key is needed before dictation or a meeting.
    case unlicensed, active, grace(daysLeft: Int), lapsed, revoked, invalid

    var tag: String {
        switch self {
        case .grace(let d): return "grace:\(d)"
        case .unlicensed: return "unlicensed"
        case .active: return "active"
        case .lapsed: return "lapsed"
        case .revoked: return "revoked"
        case .invalid: return "invalid"
        }
    }

    init?(tag: String) {
        let p = tag.split(separator: ":")
        switch (p.first.map(String.init), p.count > 1 ? Int(p[1]) : nil) {
        case ("grace", let d?): self = .grace(daysLeft: d)
        // "trial:N" / "trialExpired" are mirrors written by 0.20.x; the trial is gone, so both read as unlicensed.
        case ("unlicensed", _), ("trial", _), ("trialExpired", _): self = .unlicensed
        case ("active", _): self = .active
        case ("lapsed", _): self = .lapsed
        case ("revoked", _): self = .revoked
        case ("invalid", _): self = .invalid
        default: return nil
        }
    }
}

enum LicenseError: Error, Equatable {
    case invalid, revoked, activationLimit, network

    var message: String {
        switch self {
        case .invalid: return "That key isn't recognised. Check the email from Dodo Payments."
        case .revoked: return "This key has been disabled (refund or chargeback)."
        case .activationLimit: return "This key is already active on another Mac. Open the License pane on that Mac and choose Deactivate this Mac, then activate it here."
        case .network: return "Can't reach the license server. Keep using OpenWispr; we'll retry."
        }
    }
}

enum LicenseEvent {
    case launch
    case activated(key: String, instanceId: String)
    case validated(valid: Bool)
    case failed(LicenseError)
    case deactivated
}

enum LicenseAction { case dictate, meet }

struct LicenseStored: Equatable {
    var license: License?
}

struct LicenseOutcome: Equatable {
    var state: LicenseState
    var stored: LicenseStored
    var error: LicenseError?
    /// A /validate call should run now.
    var validateDue: Bool
}

extension License {
    static let validateEveryDays = 7.0
    static let graceDays = 21.0
    private static let day = 86_400.0

    /// State implied by what is stored, with no event.
    static func state(now: Date, stored: LicenseStored) -> LicenseState {
        if let l = stored.license {
            if l.revoked { return .revoked }
            let age = now.timeIntervalSince(l.lastValidatedAt) / day
            guard l.offline, age > validateEveryDays else { return .active }
            return age <= graceDays ? .grace(daysLeft: Int(graceDays - age.rounded(.down))) : .lapsed
        }
        return .unlicensed
    }

    static func validateDue(now: Date, stored: LicenseStored) -> Bool {
        guard let l = stored.license, !l.revoked else { return false }
        let age = now.timeIntervalSince(l.lastValidatedAt) / day
        return age < 0 || age > validateEveryDays
    }

    /// Pure: one launch or network event in, new state + what to persist out.
    static func decide(now: Date, stored: LicenseStored, event: LicenseEvent) -> LicenseOutcome {
        var s = stored
        var forced: LicenseState?
        var error: LicenseError?
        switch event {
        case .launch: break
        case .activated(let key, let id):
            s.license = License(key: key, instanceId: id, activatedAt: now, lastValidatedAt: now)
        case .validated(let valid):
            if var l = s.license {
                if valid { l.lastValidatedAt = now; l.offline = false } else { l.revoked = true }
                s.license = l
            }
            if !valid { forced = .revoked }
        case .failed(let e):
            switch e {
            case .network: s.license?.offline = true
            case .revoked: s.license?.revoked = true; forced = .revoked
            case .invalid: forced = .invalid
            case .activationLimit: error = e
            }
            if e == .invalid || e == .revoked { error = e }
        case .deactivated:
            s.license = nil
        }
        return LicenseOutcome(state: forced ?? state(now: now, stored: s), stored: s, error: error,
                              validateDue: validateDue(now: now, stored: s))
    }

    static func allows(_ action: LicenseAction, in state: LicenseState) -> Bool {
        switch state {
        case .active, .grace: return true
        case .unlicensed, .lapsed, .revoked, .invalid: return false
        }
    }

    /// Fail-safe: only an explicit `OWSourceBuild = true` in Info.plist exempts a build. Missing or false enforces.
    /// `build_app.sh` writes it for local builds; `release.sh` builds with OPENWISPR_RELEASE=1 and asserts it is absent.
    static func isSourceBuild(_ info: [String: Any]?) -> Bool { (info?["OWSourceBuild"] as? Bool) == true }

    static func allows(_ action: LicenseAction, in state: LicenseState, info: [String: Any]?) -> Bool {
        isSourceBuild(info) || allows(action, in: state)
    }

    // MARK: - Persistence (Keychain is the source of truth; UserDefaults mirrors it)

    private static let service = "org.openwispr.license"

    static func load() -> LicenseStored {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let lic = Keychain.get(service: service, account: "license")
            .flatMap { try? dec.decode(License.self, from: Data($0.utf8)) }
        // A 0.20.x trial date may still sit under account "trial"; it is ignored, so a trialing install is blocked.
        return LicenseStored(license: lic)
    }

    static func save(_ s: LicenseStored, now: Date = Date()) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let json = s.license.flatMap { try? enc.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Keychain.set(json, service: service, account: "license")
        let d = UserDefaults.standard
        d.set(state(now: now, stored: s).tag, forKey: "license.state")
        d.set(s.license?.lastValidatedAt.timeIntervalSince1970, forKey: "license.lastValidatedAt")
    }

    /// Apply an event to the persisted license and save the result.
    @discardableResult
    static func apply(_ event: LicenseEvent, now: Date = Date()) -> LicenseOutcome {
        let out = decide(now: now, stored: load(), event: event)
        save(out.stored, now: now)
        return out
    }

    // MARK: - Self-test (Swift-only; the Rust core has no licensing)

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let validatedDaysAgo: Double?
            let event: String
            let expect: String
            let expectError: Bool?
            let expectDue: Bool?
        }
        struct Gate: Decodable { let state: String; let dictate: Bool; let meet: Bool }
        let cases: [Case]
        let gate: [Gate]
    }

    static func selfTest() {
        let f = Fixtures.load(Fixture.self, "license.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
        for c in f.cases {
            let lic = c.validatedDaysAgo.map {
                License(key: "K", instanceId: "lki_1", activatedAt: ago(40), lastValidatedAt: ago($0))
            }
            let stored = LicenseStored(license: lic)
            let ev: LicenseEvent
            switch c.event {
            case "launch": ev = .launch
            case "activated": ev = .activated(key: "K", instanceId: "lki_2")
            case "valid_true": ev = .validated(valid: true)
            case "valid_false": ev = .validated(valid: false)
            case "http_404": ev = .failed(.invalid)
            case "http_403": ev = .failed(.revoked)
            case "http_422": ev = .failed(.activationLimit)
            case "network": ev = .failed(.network)
            case "deactivated": ev = .deactivated
            default: preconditionFailure("unknown license event \(c.event)")
            }
            let out = decide(now: now, stored: stored, event: ev)
            Fixtures.expectEqual(out.state.tag, c.expect, "license: \(c.name)")
            if let e = c.expectError { Fixtures.expectEqual(out.error != nil, e, "license error: \(c.name)") }
            if let d = c.expectDue { Fixtures.expectEqual(out.validateDue, d, "license due: \(c.name)") }
        }
        for g in f.gate {
            guard let st = LicenseState(tag: g.state) else { preconditionFailure("bad gate state \(g.state)") }
            Fixtures.expectEqual(allows(.dictate, in: st), g.dictate, "gate dictate \(g.state)")
            Fixtures.expectEqual(allows(.meet, in: st), g.meet, "gate meet \(g.state)")
        }
        // No key means blocked; a valid key means allowed; a 0.20.x trialing install is blocked.
        let none = state(now: now, stored: LicenseStored(license: nil))
        Fixtures.expectEqual(none, .unlicensed, "no key is unlicensed")
        Fixtures.expectEqual(allows(.dictate, in: none, info: nil), false, "no key blocks dictation")
        Fixtures.expectEqual(allows(.meet, in: none, info: nil), false, "no key blocks meetings")
        let keyed = decide(now: now, stored: LicenseStored(license: nil), event: .activated(key: "K", instanceId: "lki_1")).state
        Fixtures.expectEqual(allows(.dictate, in: keyed, info: nil), true, "valid key allows dictation")
        Fixtures.expectEqual(allows(.meet, in: keyed, info: nil), true, "valid key allows meetings")
        for legacy in ["trial:5", "trial:7", "trialExpired"] {
            let st = LicenseState(tag: legacy)
            Fixtures.expectEqual(st, .unlicensed, "legacy \(legacy) reads as unlicensed")
            Fixtures.expectEqual(st.map { allows(.dictate, in: $0, info: nil) }, false, "legacy \(legacy) blocks dictation")
        }
        Fixtures.expectEqual(decide(now: now, stored: LicenseStored(license: nil), event: .launch).state, .unlicensed,
                             "launch without a key does not start a trial")
        Fixtures.expectEqual(allows(.meet, in: .unlicensed, info: ["OWSourceBuild": true]), true, "source build needs no key")
        Fixtures.expectEqual(allows(.dictate, in: .unlicensed, info: ["OWSourceBuild": false]), false, "OWSourceBuild=false blocks")
        Fixtures.expectEqual(allows(.dictate, in: .unlicensed, info: ["OWSourceBuild": "true"]), false, "non-bool marker blocks")
        Fixtures.expectEqual(allows(.meet, in: .active, info: nil), true, "absent marker allows active license")
        LicenseClient.selfTest()
        print("License.selfTest ok (\(f.cases.count) cases)")
    }
}
