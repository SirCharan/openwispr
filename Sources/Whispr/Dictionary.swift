import Foundation

struct Replacement: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: String
    var to: String
}

struct DictionaryData: Codable, Equatable {
    var vocab: [String] = []              // preferred spellings, fuzzy-matched (e.g. "WhisperKit")
    var replacements: [Replacement] = []  // exact phrase -> replacement
}

/// Applies a user dictionary to a transcript: exact phrase replacements, then fuzzy correction
/// of near-miss words toward the user's custom vocabulary (Jaro-Winkler).
enum DictionaryStore {
    static let fuzzyThreshold = 0.86

    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("dictionary.json")
    }()

    static func load() -> DictionaryData {
        guard let data = try? Data(contentsOf: url),
              let d = try? JSONDecoder().decode(DictionaryData.self, from: data) else { return DictionaryData() }
        return d
    }

    static func save(_ d: DictionaryData) {
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: url, options: .atomic) }
    }

    static func apply(_ text: String, _ d: DictionaryData) -> String {
        var s = text
        // 1) exact phrase replacements (case-insensitive)
        for r in d.replacements where !r.from.isEmpty {
            s = s.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: r.from))\\b",
                with: r.to, options: [.regularExpression, .caseInsensitive]
            )
        }
        // 2) fuzzy-correct words toward custom vocab
        guard !d.vocab.isEmpty else { return s }
        let words = s.split(separator: " ", omittingEmptySubsequences: false)
        let corrected = words.map { word -> String in
            correctWord(String(word), vocab: d.vocab)
        }
        return corrected.joined(separator: " ")
    }

    private static func correctWord(_ word: String, vocab: [String]) -> String {
        // preserve leading/trailing punctuation
        let trimSet = CharacterSet(charactersIn: ".,!?;:\"'()")
        let core = word.trimmingCharacters(in: trimSet)
        guard core.count >= 3 else { return word }
        let lower = core.lowercased()
        // already correct (case-insensitive exact) → snap to vocab casing
        if let exact = vocab.first(where: { $0.lowercased() == lower }) {
            return word.replacingOccurrences(of: core, with: exact)
        }
        var best: (term: String, score: Double)?
        for term in vocab {
            let score = jaroWinkler(lower, term.lowercased())
            if score > (best?.score ?? 0) { best = (term, score) }
        }
        if let best, best.score >= fuzzyThreshold {
            return word.replacingOccurrences(of: core, with: best.term)
        }
        return word
    }

    // MARK: - Jaro-Winkler

    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let j = jaro(a, b)
        // common prefix up to 4
        let ca = Array(a), cb = Array(b)
        var prefix = 0
        for i in 0..<min(4, min(ca.count, cb.count)) {
            if ca[i] == cb[i] { prefix += 1 } else { break }
        }
        return j + Double(prefix) * 0.1 * (1 - j)
    }

    private static func jaro(_ a: String, _ b: String) -> Double {
        let s1 = Array(a), s2 = Array(b)
        if s1.isEmpty && s2.isEmpty { return 1 }
        if s1.isEmpty || s2.isEmpty { return 0 }
        let matchDistance = max(s1.count, s2.count) / 2 - 1
        var s1Matches = [Bool](repeating: false, count: s1.count)
        var s2Matches = [Bool](repeating: false, count: s2.count)
        var matches = 0
        for i in 0..<s1.count {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, s2.count)
            guard start < end else { continue }
            for k in start..<end where !s2Matches[k] && s1[i] == s2[k] {
                s1Matches[i] = true; s2Matches[k] = true; matches += 1; break
            }
        }
        if matches == 0 { return 0 }
        var t = 0.0, k = 0
        for i in 0..<s1.count where s1Matches[i] {
            while !s2Matches[k] { k += 1 }
            if s1[i] != s2[k] { t += 0.5 }
            k += 1
        }
        let m = Double(matches)
        return (m / Double(s1.count) + m / Double(s2.count) + (m - t) / m) / 3
    }

    static func selfTest() {
        var d = DictionaryData()
        d.vocab = ["WhisperKit", "Kubernetes"]
        d.replacements = [Replacement(from: "gonna", to: "going to")]
        let a = apply("i love whisperkit and kubernetis", d)
        assert(a.contains("WhisperKit"), "exact-case snap failed: \(a)")
        assert(a.contains("Kubernetes"), "fuzzy correct failed: \(a)")
        let b = apply("i'm gonna deploy", d)
        assert(b == "i'm going to deploy", "replacement failed: \(b)")
        assert(jaroWinkler("kubernetis", "kubernetes") > 0.9, "JW too low")
        assert(jaroWinkler("cat", "dog") < 0.5, "JW too high")
        print("DictionaryStore.selfTest PASS")
    }
}
