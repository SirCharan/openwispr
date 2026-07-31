import AppKit

/// Learn-from-corrections (Wispr/Muesli pattern, opt-in prompt, never silent):
/// after a paste, watch the clipboard for ~60s. If the user copies an edited version
/// of the transcript, diff word-by-word and offer near-miss corrections for the dictionary.
@MainActor
final class CorrectionsWatcher {
    private var lastTranscript: String?
    private var deadline = Date.distantPast
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func notePaste(_ transcript: String) {
        lastTranscript = transcript
        deadline = Date().addingTimeInterval(180)
        lastChangeCount = NSPasteboard.general.changeCount
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
    }

    private func poll() {
        guard Date() < deadline, let transcript = lastTranscript else {
            timer?.invalidate(); timer = nil
            return
        }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let copied = pb.string(forType: .string) else { return }

        let pairs = Self.corrections(original: transcript, edited: copied)
        guard !pairs.isEmpty else { return }
        offer(pairs)
        lastTranscript = nil // one offer per dictation
    }

    private func offer(_ pairs: [(from: String, to: String)]) {
        CorrectionToast.shared.show(pairs) // floating one-click prompt; never steals focus
    }

    /// Pure diff core: same-word-count texts, changed word pairs with JW 0.70–0.95
    /// (close enough to be the same intended word, different enough to matter).
    /// ponytail: equal-word-count alignment only; alignment for insert/delete edits not needed for word fixes.
    static func corrections(original: String, edited: String,
                            isRealWord: (String) -> Bool = DictionaryStore.defaultIsRealWord) -> [(from: String, to: String)] {
        let a = original.split(separator: " ").map(String.init)
        let b = edited.split(separator: " ").map(String.init)
        guard a.count == b.count, a.count > 1 else { return [] }
        // whole-string sanity: must be mostly the same text
        guard DictionaryStore.jaroWinkler(original.lowercased(), edited.lowercased()) > 0.85 else { return [] }
        var out: [(String, String)] = []
        let trim = CharacterSet(charactersIn: ".,!?;:\"'()")
        for (wa, wb) in zip(a, b) {
            let ca = wa.trimmingCharacters(in: trim), cb = wb.trimmingCharacters(in: trim)
            guard ca != cb, ca.count >= 3, cb.count >= 3 else { continue }
            if DictionaryStore.isSpellingFix(ca, cb, isRealWord: isRealWord) { out.append((ca, cb)) }
        }
        return Array(out.prefix(3)) // don't spam
    }

    static func selfTest() {
        let english: Set<String> = ["notes", "not", "able", "add", "words", "the", "cluster",
                                    "today", "deploy", "flying", "to", "tomorrow", "hello", "world"]
        let stub: (String) -> Bool = { english.contains($0.lowercased()) }

        let pairs = corrections(
            original: "deploy the kubernetis cluster today",
            edited: "deploy the Kubernetes cluster today",
            isRealWord: stub
        )
        precondition(pairs.count == 1 && pairs[0].to == "Kubernetes", "correction diff failed: \(pairs)")
        let none = corrections(original: "hello world foo", edited: "completely different text", isRealWord: stub)
        precondition(none.isEmpty, "should reject dissimilar texts")
        let same = corrections(original: "same text here", edited: "same text here", isRealWord: stub)
        precondition(same.isEmpty, "identical texts should yield nothing")
        let caseOnly = corrections(original: "flying to delhi tomorrow", edited: "flying to Delhi tomorrow", isRealWord: stub)
        precondition(caseOnly.count == 1 && caseOnly[0].to == "Delhi", "case-only fix should count: \(caseOnly)")
        // The poisoning case: editing "not" to "notes" is a content change, never a spelling fix.
        let content = corrections(original: "i am not able to add words",
                                  edited: "i am notes able to add words", isRealWord: stub)
        precondition(content.isEmpty, "must not learn ordinary English words: \(content)")
        print("CorrectionsWatcher.selfTest PASS")
    }
}
