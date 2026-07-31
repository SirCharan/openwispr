import Foundation

/// Romanize non-Latin transcripts (Devanagari → "kaise ho") via ICU transforms — stdlib, offline.
enum Transliterate {
    static func toLatin(_ text: String) -> String {
        // Any-Latin converts the script; Latin-ASCII strips diacritics (kaisē → kaise)
        text.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? text
    }

    static func selfTest() {
        let a = toLatin("कैसे हो")
        precondition(a.lowercased().contains("kaise"), "transliteration wrong: \(a)")
        let b = toLatin("hello world") // Latin input passes through
        precondition(b == "hello world", "latin passthrough wrong: \(b)")
        print("Transliterate.selfTest PASS")
    }
}
