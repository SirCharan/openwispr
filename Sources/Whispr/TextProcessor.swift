import Foundation

/// Pure-Swift cleanup applied to the raw transcript before it is pasted.
/// Whisper already punctuates, so our value-add is filler removal + capitalization/spacing normalization.
enum TextProcessor {
    struct Options {
        var removeFillers: Bool
        var cleanUp: Bool // capitalize sentences + collapse whitespace + fix standalone "i"
    }

    private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "hmm", "mmm", "uhm"]

    static func process(_ text: String, options: Options) -> String {
        var out = text
        if options.removeFillers { out = removeFillers(out) }
        if options.cleanUp { out = cleanUp(out) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeFillers(_ text: String) -> String {
        let kept = text.split(separator: " ", omittingEmptySubsequences: true).filter { word in
            let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            return !fillers.contains(bare)
        }
        return kept.joined(separator: " ")
    }

    private static func cleanUp(_ text: String) -> String {
        // collapse runs of whitespace, drop space before punctuation
        var s = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+([.,!?;:])", with: "$1", options: .regularExpression)
        s = fixStandaloneI(s)
        s = capitalizeSentences(s)
        return s
    }

    /// Capitalize the first letter and the first letter after ., !, or ?.
    private static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                result.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch == "." || ch == "!" || ch == "?" { capitalizeNext = true }
            }
        }
        return result
    }

    /// Uppercase the standalone pronoun "i" → "I".
    private static func fixStandaloneI(_ text: String) -> String {
        text.replacingOccurrences(of: "\\bi\\b", with: "I", options: .regularExpression)
    }

    static func selfTest() {
        let opts = Options(removeFillers: true, cleanUp: true)
        let a = process("um so uh this is , uh a test", options: opts)
        assert(a == "So this is, a test", "filler/cleanup wrong: \(a)")
        let b = process("i think i can . uh yes", options: opts)
        assert(b == "I think I can. Yes", "cap/I wrong: \(b)")
        let c = process("hello world", options: Options(removeFillers: false, cleanUp: false))
        assert(c == "hello world", "passthrough wrong: \(c)")
        print("TextProcessor.selfTest PASS")
    }
}
