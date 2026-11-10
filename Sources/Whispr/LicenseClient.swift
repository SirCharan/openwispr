import Foundation

/// Dodo Payments public license endpoints. No secret key: these calls need only the license key.
enum LicenseClient {
    struct Activated: Decodable { let id: String }
    struct Validated: Decodable { let valid: Bool }

    static var base: URL {
        URL(string: Settings.licenseHost == "test" ? "https://test.dodopayments.com" : "https://live.dodopayments.com")!
    }

    static func error(forStatus code: Int) -> LicenseError? {
        switch code {
        case 200..<300: return nil
        case 403: return .revoked
        case 404: return .invalid
        case 422: return .activationLimit
        default: return .network
        }
    }

    private static func post(_ path: String, _ body: [String: String]) async -> (Data, LicenseError?) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return (Data(), .network) }
        return (data, error(forStatus: http.statusCode))
    }

    /// Returns the instance id (`lki_…`).
    static func activate(key: String) async -> Result<String, LicenseError> {
        let (data, err) = await post("licenses/activate", ["license_key": key, "name": Host.current().localizedName ?? "Mac"])
        if let err { return .failure(err) }
        guard let a = try? JSONDecoder().decode(Activated.self, from: data) else { return .failure(.network) }
        return .success(a.id)
    }

    static func validate(key: String, instanceId: String) async -> Result<Bool, LicenseError> {
        let (data, err) = await post("licenses/validate", ["license_key": key, "license_key_instance_id": instanceId])
        if let err { return .failure(err) }
        guard let v = try? JSONDecoder().decode(Validated.self, from: data) else { return .failure(.network) }
        return .success(v.valid)
    }

    static func deactivate(key: String, instanceId: String) async -> LicenseError? {
        await post("licenses/deactivate", ["license_key": key, "license_key_instance_id": instanceId]).1
    }

    /// `--license-test <key> [--test]`: activate → validate → deactivate. Exit 0 only on a full round trip.
    static func runRoundTrip(key: String) async -> Int32 {
        print("host: \(base.absoluteString)")
        var stored = LicenseStored(license: nil, trialStartedAt: Date())
        switch await activate(key: key) {
        case .failure(let e): print("activate: FAIL \(e)"); return 1
        case .success(let id):
            stored = License.decide(now: Date(), stored: stored, event: .activated(key: key, instanceId: id)).stored
            print("activate: ok \(id) → \(License.state(now: Date(), stored: stored).tag)")
            switch await validate(key: key, instanceId: id) {
            case .failure(let e): print("validate: FAIL \(e)"); return 1
            case .success(let ok): print("validate: valid=\(ok)"); if !ok { return 1 }
            }
            if let e = await deactivate(key: key, instanceId: id) { print("deactivate: FAIL \(e)"); return 1 }
            stored = License.decide(now: Date(), stored: stored, event: .deactivated).stored
            print("deactivate: ok → \(License.state(now: Date(), stored: stored).tag)")
        }
        return 0
    }

    static func selfTest() {
        Fixtures.expectEqual(error(forStatus: 200), nil, "status 200")
        Fixtures.expectEqual(error(forStatus: 403), .revoked, "status 403")
        Fixtures.expectEqual(error(forStatus: 404), .invalid, "status 404")
        Fixtures.expectEqual(error(forStatus: 422), .activationLimit, "status 422")
        Fixtures.expectEqual(error(forStatus: 500), .network, "status 500")
        let a = try? JSONDecoder().decode(Activated.self, from: Data(#"{"id":"lki_abc","license_key_id":"x"}"#.utf8))
        Fixtures.expectEqual(a?.id, "lki_abc", "activate decode")
        let v = try? JSONDecoder().decode(Validated.self, from: Data(#"{"valid":false}"#.utf8))
        Fixtures.expectEqual(v?.valid, false, "validate decode")
    }
}
