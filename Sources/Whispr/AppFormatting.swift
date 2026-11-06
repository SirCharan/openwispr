import Foundation

/// Per-app output rules plus paste spacing. Adapted from Muesli (MIT) DictationAppFormatting.swift
/// and DictationPasteSpacing.swift; see THIRD-PARTY.md. Output-only: recognition and history keep the original text.
struct AppFormatting: Codable, Equatable {
    enum Capitalization: String, Codable, CaseIterable { case keep, lowercaseFirst }
    enum FinalPeriod: String, Codable, CaseIterable { case keep, drop }
    var capitalization: Capitalization = .keep
    var finalPeriod: FinalPeriod = .keep

    static let unchanged = AppFormatting()
    static let lowercaseChat = AppFormatting(capitalization: .lowercaseFirst, finalPeriod: .drop)

    func apply(to text: String) -> String {
        var s = text
        if capitalization == .lowercaseFirst, let i = s.firstIndex(where: { !$0.isWhitespace }) {
            // Only the first letter: "I'll", names and acronyms later in the text keep their case.
            s.replaceSubrange(i...i, with: s[i].lowercased())
        }
        if finalPeriod == .drop, let end = s.lastIndex(where: { !$0.isWhitespace }),
           s[end] == ".", end > s.startIndex, s[s.index(before: end)] != "." {
            s.remove(at: end) // lone final period only; "...", "?" and "!" stay
        }
        return s
    }

    /// A space after a finished sentence so back-to-back dictations don't glue together.
    /// Empty for text already ending in whitespace, CJK (no word spaces) and non-sentence endings.
    static func trailingSeparator(after text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return "" }
        var body = text[...]
        while let c = body.last, c == "\"" || c == "'" || c.unicodeScalars.allSatisfy({
            $0.properties.generalCategory == .closePunctuation || $0.properties.generalCategory == .finalPunctuation
        }) { body.removeLast() }
        guard let end = body.last, matches(#"[\p{Sentence_Terminal}…]"#, end),
              let prev = body.dropLast().last(where: { $0.isLetter || $0.isNumber }),
              !matches(#"[\p{Han}\p{Hiragana}\p{Katakana}\p{Bopomofo}]"#, prev) else { return "" }
        return " "
    }

    private static func matches(_ pattern: String, _ c: Character) -> Bool {
        String(c).range(of: pattern, options: .regularExpression) != nil
    }

    /// Bundle id → rule, stored as JSON in UserDefaults.
    static var rules: [String: AppFormatting] {
        get {
            (UserDefaults.standard.data(forKey: "appFormatting")
                .flatMap { try? JSONDecoder().decode([String: AppFormatting].self, from: $0) }) ?? [:]
        }
        set {
            let active = newValue.filter { $0.value != .unchanged }
            UserDefaults.standard.set(try? JSONEncoder().encode(active), forKey: "appFormatting")
        }
    }

    static func apply(_ text: String, bundleID: String?) -> String {
        guard let bundleID, let rule = rules[bundleID] else { return text }
        return rule.apply(to: text)
    }

    struct Fixture: Decodable {
        struct Format: Decodable { let text: String; let capitalization: String; let finalPeriod: String; let expected: String }
        struct Spacing: Decodable { let text: String; let expected: String }
        let format: [Format]
        let spacing: [Spacing]
    }

    static func selfTest() {
        let f = Fixtures.load(Fixture.self, "formatting.json")
        Fixtures.expect(f.format.count >= 8, "formatting.json needs >= 8 format cases")
        for c in f.format {
            let rule = AppFormatting(capitalization: Capitalization(rawValue: c.capitalization)!,
                                     finalPeriod: FinalPeriod(rawValue: c.finalPeriod)!)
            Fixtures.expectEqual(rule.apply(to: c.text), c.expected, "format \(c.text.debugDescription)")
        }
        for c in f.spacing {
            Fixtures.expectEqual(trailingSeparator(after: c.text), c.expected, "spacing \(c.text.debugDescription)")
        }
        print("AppFormatting.selfTest PASS (\(f.format.count + f.spacing.count) cases)")
    }
}
