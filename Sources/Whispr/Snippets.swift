import Foundation

/// Voice shortcuts: a spoken trigger phrase expands to canned text (email, address, code, boilerplate).
/// Reuses `Replacement` (from = trigger, to = expansion). Applied after cleanup so expansions keep exact casing.
enum SnippetStore {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("snippets.json")
    }()

    static func load() -> [Replacement] {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode([Replacement].self, from: data) else { return [] }
        return s
    }

    static func save(_ s: [Replacement]) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    static func apply(_ text: String, _ snippets: [Replacement]) -> String {
        var s = text
        for snip in snippets where !snip.from.isEmpty {
            s = s.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: snip.from))\\b",
                with: snip.to, options: [.regularExpression, .caseInsensitive]
            )
        }
        return s
    }

    /// Driven by `core/fixtures/snippets.json`, the same table the Rust port is held to.
    ///
    /// The fixtures carry bare from/to pairs. `Replacement` cannot decode them directly: its
    /// `id` has a default value, and Swift's synthesized decoder ignores defaults and demands
    /// the key. So the pair is decoded on its own and mapped.
    private struct FixtureFile: Decodable {
        struct Pair: Decodable {
            let from: String
            let to: String
        }
        struct Case: Decodable {
            let snippets: [Pair]
            let input: String
            let expected: String
        }
        let cases: [Case]
    }

    static func selfTest() {
        let f = Fixtures.load(FixtureFile.self, "snippets.json")
        Fixtures.expect(!f.cases.isEmpty, "snippets.json has no cases")
        for c in f.cases {
            let snips = c.snippets.map { Replacement(from: $0.from, to: $0.to) }
            Fixtures.expectEqual(apply(c.input, snips), c.expected, "apply(\(c.input))")
        }
        print("SnippetStore.selfTest PASS (\(f.cases.count) cases)")
    }
}
