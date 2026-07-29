import AppKit
import ApplicationServices

/// Watches the text field we pasted into (via Accessibility) and offers spelling corrections
/// the user makes IN PLACE — no copying required. Polls the field's AXValue every 3 s for up
/// to 3 min; stops early when the element dies or a new dictation starts.
@MainActor
final class AXEditWatcher {
    private var element: AXUIElement?
    private var baseline = ""       // field value right after paste
    private var transcript = ""     // what we pasted
    private var timer: Timer?
    private var deadline = Date.distantPast
    private var offered = false

    /// Call right after a successful paste, while the target field still has focus.
    func watch(transcript: String) {
        stop()
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused else { return } // no AX permission or no focused element — clipboard path still covers us
        let axEl = unsafeDowncast(el, to: AXUIElement.self)
        guard let value = Self.stringValue(of: axEl) else { return } // element has no readable text
        element = axEl
        baseline = value
        self.transcript = transcript
        offered = false
        deadline = Date().addingTimeInterval(180)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        element = nil
    }

    private func poll() {
        guard Date() < deadline, !offered, let element else { stop(); return }
        guard let current = Self.stringValue(of: element) else { stop(); return } // element gone
        guard current != baseline else { return }
        let pairs = Self.pairs(transcript: transcript, before: baseline, after: current)
        guard !pairs.isEmpty else {
            baseline = current // absorb unrelated edits so we diff against the latest state
            return
        }
        offered = true
        CorrectionToast.shared.show(pairs)
        stop()
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let s = value as? String else { return nil }
        return s
    }

    // MARK: - Pairing (pure; position-independent so surrounding edits don't break it)

    /// Words from the transcript that vanished from the field × new words that appeared,
    /// paired by `DictionaryStore.isSpellingFix` (case-only, or similar enough and not ordinary English).
    static func pairs(transcript: String, before: String, after: String,
                      isRealWord: (String) -> Bool = DictionaryStore.defaultIsRealWord) -> [(from: String, to: String)] {
        let trim = CharacterSet(charactersIn: ".,!?;:\"'()")
        func words(_ s: String) -> [String] {
            s.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .map { $0.trimmingCharacters(in: trim) }
                .filter { $0.count >= 3 }
        }
        let transcriptWords = Set(words(transcript))
        let beforeSet = Set(words(before))
        let afterSet = Set(words(after))
        let gone = transcriptWords.subtracting(afterSet)          // our words the user removed/changed
        let appeared = afterSet.subtracting(beforeSet)            // words that are new since paste
        var out: [(String, String)] = []
        for from in gone {
            for to in appeared where out.count < 3 {
                if DictionaryStore.isSpellingFix(from, to, isRealWord: isRealWord) {
                    out.append((from, to)); break
                }
            }
        }
        return out
    }

    static func selfTest() {
        let english: Set<String> = ["notes", "not", "now", "please", "deploy", "send", "the",
                                    "report", "ship", "document", "able"]
        let stub: (String) -> Bool = { english.contains($0.lowercased()) }
        // in-place fix survives an unrelated inserted word
        let p = pairs(transcript: "deploy kubernetis now",
                      before: "notes:\ndeploy kubernetis now",
                      after: "notes:\ndeploy Kubernetes now please",
                      isRealWord: stub)
        assert(p.count == 1 && p[0].to == "Kubernetes", "AX pair failed: \(p)")
        // pure rephrase: nothing similar appeared → no pairs
        let r = pairs(transcript: "send the report",
                      before: "send the report",
                      after: "ship the document",
                      isRealWord: stub)
        assert(r.isEmpty, "rephrase should not pair: \(r)")
        // a content edit toward ordinary English must never be learned
        let c = pairs(transcript: "i am not able",
                      before: "i am not able",
                      after: "i am notes able",
                      isRealWord: stub)
        assert(c.isEmpty, "must not learn ordinary English words: \(c)")
        print("AXEditWatcher.selfTest PASS")
    }
}
