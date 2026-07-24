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

    static func selfTest() {
        let snips = [Replacement(from: "my email", to: "ck@example.com")]
        let a = apply("please send my email now", snips)
        assert(a == "please send ck@example.com now", "snippet expand failed: \(a)")
        print("SnippetStore.selfTest PASS")
    }
}
