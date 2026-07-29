import Foundation
#if canImport(AppKit)
import AppKit
#endif

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
    static let fuzzyThreshold = 0.86       // words of 6+ characters
    static let shortWordThreshold = 0.92   // 3-5 characters: one edit is a large share of a short word
    static let phraseThreshold = 0.92      // two spoken words merged into one vocab term

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

    static func apply(_ text: String, _ d: DictionaryData,
                      isRealWord: (String) -> Bool = defaultIsRealWord) -> String {
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
        let words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            // Prefer a two-word match, so "open whisper" beats correcting each half separately.
            if i + 1 < words.count,
               let merged = mergedMatch(words[i], words[i + 1], vocab: d.vocab, isRealWord: isRealWord) {
                out.append(merged)
                i += 2
                continue
            }
            out.append(correctWord(words[i], vocab: d.vocab, isRealWord: isRealWord))
            i += 1
        }
        return out.joined(separator: " ")
    }

    private static func correctWord(_ word: String, vocab: [String], isRealWord: (String) -> Bool) -> String {
        // preserve leading/trailing punctuation
        let trimSet = CharacterSet(charactersIn: ".,!?;:\"'()")
        let core = word.trimmingCharacters(in: trimSet)
        guard core.count >= 3 else { return word }
        let lower = core.lowercased()
        // already correct (case-insensitive exact) → snap to vocab casing
        if let exact = vocab.first(where: { $0.lowercased() == lower }) {
            return word.replacingOccurrences(of: core, with: exact)
        }
        // An ordinary English word is what the speaker meant. Never rewrite it.
        // Without this guard "not" becomes "notes" whenever "notes" is in the vocab list
        // (Jaro-Winkler scores them 0.907), and every such rewrite corrupts a dictation.
        guard !isRealWord(lower) else { return word }
        var best: (term: String, score: Double)?
        for term in vocab {
            let score = similarity(lower, term.lowercased())
            if score > (best?.score ?? 0) { best = (term, score) }
        }
        if let best, best.score >= threshold(forLength: core.count) {
            return word.replacingOccurrences(of: core, with: best.term)
        }
        return word
    }

    /// Two spoken words that together sound like one vocab term ("open whisper" → "OpenWispr").
    /// The halves are deliberately NOT real-word-guarded: both "open" and "whisper" are ordinary
    /// words, and guarding them would defeat the only case this exists for. Instead the *joined*
    /// form must not be a real word ("not able" → "notable" is rejected here), the vocab term must
    /// be long enough to be a proper noun, and the bar is raised to `phraseThreshold`.
    private static func mergedMatch(_ a: String, _ b: String, vocab: [String],
                                    isRealWord: (String) -> Bool) -> String? {
        let trimSet = CharacterSet(charactersIn: ".,!?;:\"'()")
        let coreA = a.trimmingCharacters(in: trimSet)
        let coreB = b.trimmingCharacters(in: trimSet)
        guard coreA.count >= 2, coreB.count >= 2 else { return nil }
        // a merge would swallow punctuation sitting between or before the pair
        guard coreA == a, let rangeB = b.range(of: coreB), rangeB.lowerBound == b.startIndex else { return nil }
        let joined = (coreA + coreB).lowercased()
        guard !isRealWord(joined) else { return nil }
        var best: (term: String, score: Double)?
        for term in vocab where term.count >= 6 {
            let flat = term.replacingOccurrences(of: " ", with: "").lowercased()
            // a merge should be about the same length as its target, not a term plus a stray word
            guard abs(flat.count - joined.count) <= 3 else { continue }
            let score = similarity(joined, flat)
            if score > (best?.score ?? 0) { best = (term, score) }
        }
        // The merge must beat what the first word achieves alone, or "stratsea and" swallows "and":
        // the joined form still scores high because Jaro-Winkler rewards the shared prefix.
        var soloBest = 0.0
        if !isRealWord(coreA.lowercased()) {
            for term in vocab {
                soloBest = max(soloBest, similarity(coreA.lowercased(), term.lowercased()))
            }
        }
        guard let best, best.score >= phraseThreshold, best.score > soloBest else { return nil }
        return best.term + String(b[rangeB.upperBound...])   // keep trailing punctuation
    }

    private static func threshold(forLength n: Int) -> Double {
        n >= 6 ? fuzzyThreshold : shortWordThreshold
    }

    /// Best of the spelled and the sounded match. Whisper mis-hears proper nouns phonetically,
    /// so "stratsea" is only 0.868 against "Stratzy" by spelling but 1.0 by sound.
    static func similarity(_ a: String, _ b: String) -> Double {
        max(jaroWinkler(a, b), jaroWinkler(phoneticKey(a), phoneticKey(b)))
    }

    // MARK: - Phonetic key

    /// Reduces a word to roughly what it sounds like: drop vowels after the first, fold letters
    /// that share a sound (c/q→k, z→s, d→t, b→p, v→f, g→k, x→ks), collapse doubles.
    /// "stratsea" and "Stratzy" both reduce to "strts".
    static func phoneticKey(_ s: String) -> String {
        var w = s.lowercased()
        for (from, to) in [("ph", "f"), ("ck", "k"), ("qu", "kw")] {
            w = w.replacingOccurrences(of: from, with: to)
        }
        let fold: [Character: String] = ["c": "k", "q": "k", "z": "s", "x": "ks",
                                         "v": "f", "g": "k", "d": "t", "b": "p"]
        var folded = ""
        for (i, ch) in w.enumerated() {
            guard ch.isLetter else { continue }
            if "aeiouy".contains(ch) {
                if i == 0 { folded.append(ch) }   // a leading vowel still distinguishes the word
                continue
            }
            folded += fold[ch] ?? String(ch)
        }
        var collapsed = ""
        for ch in folded where collapsed.last != ch { collapsed.append(ch) }
        return collapsed
    }

    // MARK: - Learning from user edits

    /// Is an edit from one word to another a spelling correction worth learning, or a content change?
    /// Shared by `CorrectionsWatcher` (clipboard diff) and `AXEditWatcher` (accessibility diff),
    /// which previously each carried their own copy of a band that got this backwards.
    static func isSpellingFix(_ from: String, _ to: String,
                              isRealWord: (String) -> Bool = defaultIsRealWord) -> Bool {
        let a = from.lowercased(), b = to.lowercased()
        guard from != to else { return false }
        if a == b { return true }                    // case-only fix: "delhi" → "Delhi"
        guard !isRealWord(b) else { return false }   // edited into ordinary English = content change
        return jaroWinkler(a, b) >= 0.70             // floor only; see the guard above
    }

    // MARK: - Real-word guard

    private nonisolated(unsafe) static var realWordCache: [String: Bool] = [:]
    private static let realWordLock = NSLock()

    /// Is this an ordinary English word? Backed by the macOS spell checker, which knows the
    /// inflections `/usr/share/dict/words` omits — that list has no "notes", "nodes" or "models",
    /// which are exactly the words that were being corrupted.
    /// Injected into `apply` so the headless self-test stays deterministic and AppKit-free.
    static func defaultIsRealWord(_ word: String) -> Bool {
        let key = word.lowercased()
        realWordLock.lock()
        let cached = realWordCache[key]
        realWordLock.unlock()
        if let cached { return cached }
        #if canImport(AppKit)
        // checkSpelling returns the range of the first misspelling; NSNotFound means it is a word.
        let known = NSSpellChecker.shared.checkSpelling(of: key, startingAt: 0).location == NSNotFound
        #else
        let known = false
        #endif
        realWordLock.lock()
        realWordCache[key] = known
        realWordLock.unlock()
        return known
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
        // Stub English so the gate is deterministic and needs no AppKit spell checker.
        let english: Set<String> = ["i", "am", "not", "able", "to", "add", "words", "notable",
                                    "note", "noted", "nodes", "node", "mode", "model", "models",
                                    "mobile", "open", "whisper", "love", "and", "deploy", "delta",
                                    "the", "see", "here"]
        let stub: (String) -> Bool = { english.contains($0.lowercased()) }

        var d = DictionaryData()
        d.vocab = ["WhisperKit", "Kubernetes"]
        d.replacements = [Replacement(from: "gonna", to: "going to")]
        let a = apply("i love whisperkit and kubernetis", d, isRealWord: stub)
        assert(a.contains("WhisperKit"), "exact-case snap failed: \(a)")
        assert(a.contains("Kubernetes"), "fuzzy correct failed: \(a)")
        let b = apply("i'm gonna deploy", d, isRealWord: stub)
        assert(b == "i'm going to deploy", "replacement failed: \(b)")
        assert(jaroWinkler("kubernetis", "kubernetes") > 0.9, "JW too low")
        assert(jaroWinkler("cat", "dog") < 0.5, "JW too high")

        // Regression: ordinary English must survive a vocab full of look-alikes.
        // This exact sentence came out as "i am notes able to add words" before the guard.
        var e = DictionaryData()
        e.vocab = ["notes", "model", "mobile", "Stratzy", "OpenWispr", "Obsidian"]
        let plain = apply("i am not able to add words", e, isRealWord: stub)
        assert(plain == "i am not able to add words", "real words must survive: \(plain)")
        for w in ["note", "noted", "nodes", "mode", "models"] {
            let out = apply(w, e, isRealWord: stub)
            assert(out == w, "\(w) must not be rewritten: \(out)")
        }

        // Recall: phonetic near-misses of proper nouns must still be corrected.
        assert(apply("stratsea", e, isRealWord: stub) == "Stratzy", "phonetic single-word failed")
        assert(apply("kubernetis", d, isRealWord: stub) == "Kubernetes", "phonetic single-word failed")
        assert(apply("strat see", e, isRealWord: stub) == "Stratzy", "two-word merge failed")
        assert(apply("open whisper", e, isRealWord: stub) == "OpenWispr", "two-word merge failed")
        assert(apply("open whisper.", e, isRealWord: stub) == "OpenWispr.", "merge dropped punctuation")
        // a merge must never swallow the next word when the first already matches on its own
        assert(apply("stratsea and here", e, isRealWord: stub) == "Stratzy and here",
               "merge swallowed a word: \(apply("stratsea and here", e, isRealWord: stub))")

        // Casing snap still wins over the guard: "delta" is a real word AND a vocab entry.
        var k = DictionaryData()
        k.vocab = ["Delta"]
        assert(apply("delta", k, isRealWord: stub) == "Delta", "case snap must beat the real-word guard")

        assert(phoneticKey("Stratzy") == phoneticKey("stratsea"), "phonetic key mismatch")
        assert(phoneticKey("Kubernetes") == phoneticKey("kubernetis"), "phonetic key mismatch")
        assert(phoneticKey("cat") != phoneticKey("dog"), "phonetic key collision")
        print("DictionaryStore.selfTest PASS")
    }
}
