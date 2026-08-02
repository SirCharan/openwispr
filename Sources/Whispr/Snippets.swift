import Foundation

/// One voice shortcut: any of `triggers`, spoken while dictating, expands to `to`.
///
/// Several triggers per snippet because Whisper writes the same phrase more than one way —
/// "add my linkedin", "add my linked in". `id` decodes as optional so a hand-edited
/// `snippets.json` (and the shared fixtures) still load.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var triggers: [String]
    var to: String

    init(triggers: [String], to: String) {
        self.triggers = triggers
        self.to = to
    }

    private enum CodingKeys: String, CodingKey { case id, triggers, to }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        triggers = try c.decodeIfPresent([String].self, forKey: .triggers) ?? []
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
    }
}

/// Voice shortcuts: a spoken trigger phrase expands to canned text (email, address, boilerplate).
/// Applied after cleanup so expansions keep their exact casing.
///
/// Expansion is a two-step pass so an LLM rewrite cannot mangle an email address or URL:
/// `expand` swaps each expansion for a sentinel, the caller rewrites around the sentinels,
/// and `restore` puts the expansions back. Mirrored by `core/src/snippets.rs`.
enum SnippetStore {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("snippets.json")
    }()

    static func load() -> [Snippet] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let s = try? JSONDecoder().decode([Snippet].self, from: data) { return s }
        // Snippets shipped as `[{from, to}]` before triggers were a list. Read the old shape
        // rather than drop what a user already typed; the next save writes the new one.
        if let legacy = try? JSONDecoder().decode([Replacement].self, from: data) {
            return legacy.map { Snippet(triggers: [$0.from], to: $0.to) }
        }
        return []
    }

    static func save(_ s: [Snippet]) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    /// A private-use codepoint: it survives a rewrite better than punctuation an LLM would tidy,
    /// and it is not a word character, so `\b` still matches around it.
    static func token(_ n: Int) -> String { "\u{E000}\(n)\u{E000}" }

    /// Expansions swapped for sentinels, plus the table that puts them back.
    struct Expansion {
        let protectedText: String
        /// Sentinel to expansion, in the order the sentinels were assigned.
        let tokens: [(token: String, to: String)]

        /// The transcript with every expansion in place. Restoring its own sentinels cannot fail.
        var expandedText: String { SnippetStore.restore(protectedText, tokens: tokens) ?? protectedText }
    }

    static func expand(_ text: String, _ snippets: [Snippet]) -> Expansion {
        // Longest trigger first, so "add my email signature" beats "add my email" wherever both
        // could match. Swift's sort is not stable, so equal lengths fall back to row order.
        var pairs: [(trigger: String, to: String)] = []
        for snip in snippets where !snip.to.isEmpty {  // an unfilled preset row is inert
            for raw in snip.triggers {
                let trigger = raw.trimmingCharacters(in: .whitespaces)
                if !trigger.isEmpty { pairs.append((trigger, snip.to)) }
            }
        }
        let order = pairs.indices.sorted { a, b in
            let la = pairs[a].trigger.count, lb = pairs[b].trigger.count
            return la == lb ? a < b : la > lb
        }

        var protectedText = text
        var tokens: [(token: String, to: String)] = []
        for i in order {
            let pair = pairs[i]
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: pair.trigger))\\b"
            let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
            guard protectedText.range(of: pattern, options: options) != nil else { continue }
            let tok = token(tokens.count)
            // The sentinel goes in, not the expansion: nothing already expanded is ever rescanned,
            // and `$` in an expansion stays literal instead of reading as a capture reference.
            protectedText = protectedText.replacingOccurrences(of: pattern, with: tok, options: options)
            tokens.append((tok, pair.to))
        }
        return Expansion(protectedText: protectedText, tokens: tokens)
    }

    /// Puts the expansions back. `nil` when a sentinel is missing — a rewrite dropped it, and the
    /// caller should fall back to `Expansion.expandedText` rather than paste a half-expanded line.
    static func restore(_ text: String, tokens: [(token: String, to: String)]) -> String? {
        var s = text
        for t in tokens {
            guard s.contains(t.token) else { return nil }
            s = s.replacingOccurrences(of: t.token, with: t.to)
        }
        return s
    }

    /// Expand with no rewrite in between.
    static func apply(_ text: String, _ snippets: [Snippet]) -> String {
        expand(text, snippets).expandedText
    }

    // MARK: - Presets

    /// Starter rows for the details people paste most often. Expansions are deliberately empty:
    /// nothing personal ships in the binary, and an unfilled row is inert until it is filled in.
    static let presets: [Snippet] = [
        Snippet(triggers: ["add my email", "add my e-mail", "add my e mail", "my email address"], to: ""),
        Snippet(triggers: ["add my linkedin", "add my linked in", "my linkedin"], to: ""),
        Snippet(triggers: ["add my twitter", "add my x handle", "my twitter"], to: ""),
        Snippet(triggers: ["add my github", "add my git hub", "my github"], to: ""),
        Snippet(triggers: ["add my phone", "add my number", "my phone number"], to: ""),
        Snippet(triggers: ["add my signature", "add my sign off"], to: ""),
    ]

    /// Presets whose first trigger is not already in use, so the button never adds a duplicate.
    static func missingPresets(from items: [Snippet]) -> [Snippet] {
        let taken = Set(items.flatMap { $0.triggers.map { $0.lowercased() } })
        return presets.filter { preset in !preset.triggers.contains { taken.contains($0.lowercased()) } }
    }

    // MARK: - Self-test

    /// Driven by `core/fixtures/snippets.json`, the same table the Rust port is held to.
    private struct FixtureFile: Decodable {
        struct Case: Decodable {
            let snippets: [Snippet]
            let input: String
            let expected: String
        }
        struct ProtectCase: Decodable {
            let snippets: [Snippet]
            let input: String
            let expanded: String
            /// `{n}` stands for the nth sentinel.
            let rewritten: String
            let expected: String?
        }
        let cases: [Case]
        let protect: [ProtectCase]
    }

    static func selfTest() {
        let f = Fixtures.load(FixtureFile.self, "snippets.json")
        Fixtures.expect(!f.cases.isEmpty, "snippets.json has no cases")
        for c in f.cases {
            Fixtures.expectEqual(apply(c.input, c.snippets), c.expected, "apply(\(c.input))")
        }
        Fixtures.expect(!f.protect.isEmpty, "snippets.json has no protect cases")
        for c in f.protect {
            let e = expand(c.input, c.snippets)
            Fixtures.expectEqual(e.expandedText, c.expanded, "expanded(\(c.input))")
            var rewritten = c.rewritten
            for (i, t) in e.tokens.enumerated() {
                rewritten = rewritten.replacingOccurrences(of: "{\(i)}", with: t.token)
            }
            let got = restore(rewritten, tokens: e.tokens)
            Fixtures.expectEqual(got ?? "<nil>", c.expected ?? "<nil>", "restore(\(c.rewritten))")
        }
        print("SnippetStore.selfTest PASS (\(f.cases.count) cases, \(f.protect.count) protect)")
    }
}
