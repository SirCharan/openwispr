import Foundation

/// Which backend Summarize will use.
enum SummaryChoice: Equatable {
    case provider(LLMProvider)   // Ollama / OpenAI / OpenRouter
    case apple
    case none

    var label: String {
        switch self {
        case .provider(let p): p.label
        case .apple: "Apple on-device model"
        case .none: "no AI model"
        }
    }
}

/// Provider resolution + map-reduce summarising. Pure pieces are selftested.
enum SummaryEngine {
    static let systemPrompt = """
    You summarize meeting transcripts. "You" is the local user; other names/speakers are remote participants.
    Reply in Markdown with exactly three sections, with these headings and nothing else in the heading lines: "## Summary", "## Decisions", "## Action items".
    Under Summary write 2-4 sentences. Under Decisions write bullets, or None. Under Action items write bullets with the owner if known, or None.
    """
    static let partPrompt = """
    You summarize one part of a longer meeting transcript. "You" is the local user; other names/speakers are remote participants.
    Reply with short bullets: key points, decisions made, action items (with owner if known). No preamble.
    """
    static let chunkWords = 2500

    /// Explicit AI-settings choice if set and reachable, else Ollama if up, else Apple if ready, else none.
    static func resolve(explicit: LLMProvider?, explicitReady: Bool, ollamaUp: Bool, appleReady: Bool) -> SummaryChoice {
        if let explicit, explicitReady { return .provider(explicit) }
        if ollamaUp { return .provider(.ollama) }
        if appleReady { return .apple }
        return .none
    }

    static func resolveLive() async -> SummaryChoice {
        let raw = UserDefaults.standard.string(forKey: "llmProvider")
        let explicit = raw.flatMap(LLMProvider.init(rawValue:))
        let ollama = await LLMClient.ollamaAlive()
        var ready = false
        if let explicit { ready = explicit == .ollama ? ollama : (LLMClient.apiKey(for: explicit)?.isEmpty == false) }
        return resolve(explicit: explicit, explicitReady: ready, ollamaUp: ollama, appleReady: AppleLocalEngine.isAvailable())
    }

    /// Split on line boundaries into chunks of at most `maxWords` words; an over-long line is split by words.
    static func chunk(_ text: String, maxWords: Int = chunkWords) -> [String] {
        var out: [String] = []
        var cur: [String] = []
        var n = 0
        func flush() { if !cur.isEmpty { out.append(cur.joined(separator: "\n")); cur = []; n = 0 } }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.count > maxWords {
                flush()
                var i = 0
                while i < words.count {
                    out.append(words[i..<min(i + maxWords, words.count)].joined(separator: " "))
                    i += maxWords
                }
                continue
            }
            if n + words.count > maxWords { flush() }
            cur.append(String(line)); n += words.count
        }
        flush()
        return out
    }

    private static func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

    private static func call(_ choice: SummaryChoice, system: String, user: String) async throws -> String {
        switch choice {
        case .apple: return try await AppleLocalEngine.complete(system: system, user: user)
        case .provider(let p): return try await LLMClient.complete(system: system, user: user, using: p)
        case .none: throw LLMError.notConfigured
        }
    }

    /// Short transcripts go straight through. Long ones: summarise each chunk, then summarise the summaries.
    /// The Apple model has a ~4k-token window, so a chunk that still overflows is retried at half size.
    static func summarize(transcript: String, choice: SummaryChoice, maxWords: Int = chunkWords) async throws -> String {
        let parts = chunk(transcript, maxWords: maxWords)
        if parts.count <= 1 {
            do { return try await call(choice, system: systemPrompt, user: transcript) }
            catch where choice == .apple && maxWords > 300 && wordCount(transcript) > 300 {
                return try await summarize(transcript: transcript, choice: choice, maxWords: max(300, wordCount(transcript) / 2))
            }
        }
        var partials: [String] = []
        for (i, p) in parts.enumerated() {
            let s = try await call(choice, system: partPrompt, user: p)
            partials.append("Part \(i + 1):\n\(s)")
        }
        let joined = partials.joined(separator: "\n\n")
        if wordCount(joined) > maxWords {
            return try await summarize(transcript: joined, choice: choice, maxWords: maxWords)
        }
        return try await call(choice, system: systemPrompt, user: joined)
    }

    static func selfTest() {
        typealias C = SummaryChoice
        precondition(resolve(explicit: .openai, explicitReady: true, ollamaUp: true, appleReady: true) == C.provider(.openai), "explicit ready must win")
        precondition(resolve(explicit: .openai, explicitReady: false, ollamaUp: true, appleReady: true) == C.provider(.ollama), "unready explicit falls to ollama")
        precondition(resolve(explicit: nil, explicitReady: false, ollamaUp: true, appleReady: true) == C.provider(.ollama), "ollama before apple")
        precondition(resolve(explicit: nil, explicitReady: false, ollamaUp: false, appleReady: true) == C.apple, "apple when alone")
        precondition(resolve(explicit: .openrouter, explicitReady: false, ollamaUp: false, appleReady: true) == C.apple, "apple after dead explicit")
        precondition(resolve(explicit: nil, explicitReady: false, ollamaUp: false, appleReady: false) == C.none, "none")
        print("SummaryEngine.resolve selfTest PASS (6 cases)")

        let line = Array(repeating: "word", count: 40).joined(separator: " ")
        let text = (0..<250).map { _ in "You: \(line)" }.joined(separator: "\n") // 250 * 41 = 10,250 words
        let chunks = chunk(text)
        precondition(chunks.count >= 4, "expected >=4 chunks, got \(chunks.count)")
        precondition(chunks.allSatisfy { wordCount($0) <= chunkWords }, "chunk over 2500 words")
        precondition(chunks.reduce(0) { $0 + wordCount($1) } == 10_250, "words lost in chunking")
        let one = chunk(Array(repeating: "w", count: 10_000).joined(separator: " "))
        precondition(one.count == 4 && one.allSatisfy { wordCount($0) <= chunkWords }, "single long line")
        print("SummaryEngine.chunk selfTest PASS (\(chunks.count) chunks of ≤\(chunkWords) words from 10,250; single line → \(one.count))")
    }
}
