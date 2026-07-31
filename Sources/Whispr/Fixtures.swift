import Foundation

/// Loads the shared parity fixtures in `core/fixtures/`.
///
/// The same JSON files drive the Rust tests in `core/` and the Swift `--selftest`, so a
/// behaviour difference between the macOS and Windows builds fails CI on both instead of
/// reaching users on one of them.
///
/// Resolution order: `OPENWISPR_FIXTURES` (CI and dev override) → the app bundle's
/// `Resources/fixtures` (assembled by `build_app.sh`) → the repository checkout, derived
/// from this file's own path so `swift run` works without any setup.
enum Fixtures {
    static func directory() -> URL {
        if let override = ProcessInfo.processInfo.environment["OPENWISPR_FIXTURES"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("fixtures", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Sources/Whispr/Fixtures.swift → repository root → core/fixtures
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Whispr
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("core/fixtures", isDirectory: true)
    }

    /// Decode one fixture file. A missing or malformed fixture is a broken gate, not a
    /// runtime condition, so it stops the process with the offending path.
    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T {
        let url = directory().appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            preconditionFailure("cannot read fixture \(url.path)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            preconditionFailure("cannot parse fixture \(url.path): \(error)")
        }
    }

    /// Fail a self-test with a readable message.
    ///
    /// Not `assert`: the optimizer strips it, so a release build printed PASS while checking
    /// nothing. Not `precondition` either: it checks in release but traps without emitting its
    /// message, leaving CI an exit code and no clue which case broke. Printing and exiting gives
    /// both.
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
        exit(1)
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fail(message()) }
    }

    /// Compare two values in a self-test, reporting both sides on failure.
    static func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: @autoclosure () -> String) {
        if got != want { fail("\(label()): got \(got), want \(want)") }
    }

    static func expectClose(_ got: Double, _ want: Double, _ label: @autoclosure () -> String) {
        if abs(got - want) >= 0.001 { fail("\(label()): got \(got), want \(want)") }
    }
}
