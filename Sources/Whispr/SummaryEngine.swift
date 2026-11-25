import Foundation
import NaturalLanguage

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
    You write specific meeting notes from a transcript. Lines look like "[mm:ss] Speaker: text". "You" is the local user; other names/speakers are remote participants.
    Write in English even if the transcript is Hindi or Hinglish; keep proper nouns, product names and numbers as spoken.
    The recording may also contain a film, TV, music, a video or an unrelated conversation in the room. Leave such passages out of all three sections. If a large part of the recording is not a meeting, add one line at the top of Topics discussed, for example "Note: from about 107:00 the recording is background media, not the meeting".
    Reply in Markdown with exactly these three sections, in this order, with these exact headings:
    ## Topics discussed
    Synthesise, do not quote. Each bullet is: **Short topic title** [mm:ss]: one or two sentences in your own words stating what was said, with the names, numbers, products and dates involved. Group related remarks under one topic. No verbatim quote longer than a short phrase. [mm:ss] is where the topic starts.
    ## Decisions
    Only where the transcript shows a choice being settled (agreed, decided, going with, will not): what was decided and who decided it. Otherwise write None.
    ## Action items
    Only where someone commits to doing something or is asked to do it ("I will", "can you", "please", "we need to", "let's", an imperative aimed at a person). A remark, a question or a description is not an action item. Rewrite each as a short imperative task, one bullet each:
    - **Task in a few words** · Owner: <name or Unassigned> · Due: <date or Not stated> · [mm:ss]
    If there are none, write None. Fewer real items beat many doubtful ones.
    Rules:
    - Never write general sentences such as "a range of topics were covered" or "action items were assigned". Every bullet must contain a concrete fact from the transcript.
    - Owner is a name or speaker label that appears in the transcript, otherwise "Unassigned".
    - Due is the date or deadline stated, otherwise "Not stated". If the user message gives the meeting date, look a relative deadline up in the date table and write that date followed by the original words in brackets, e.g. 18 Nov 2026 (by Wednesday). If the phrase is not in the table or is ambiguous, keep the speaker's words unchanged. Never compute a date yourself.
    - Never guess an owner or a date.
    """
    static let partPrompt = """
    You extract notes from one part of a longer meeting transcript. Lines look like "[mm:ss] Speaker: text". "You" is the local user; other names/speakers are remote participants.
    Skip any film, TV, music, video or unrelated conversation in the room; if this part is mostly that, reply only "Not a meeting: <what it is>, from [mm:ss]".
    Reply with bullets only, under three headings, no preamble. Write in English; keep proper nouns as spoken.
    Topics: **Short topic title** [mm:ss] (speaker): one or two sentences in your own words with the names, numbers, products and dates involved. Group related remarks; no long quotes.
    Decisions: only where a choice was settled (agreed, decided, going with, will not), with who decided and [mm:ss]. Otherwise "None".
    Tasks: only where someone commits ("I will", "we need to", "let's") or is asked ("can you", "please", an imperative at a person). A remark, question or description is not a task. Write a short imperative with Owner (name or Unassigned), Due (the deadline in the speaker's own words, unconverted, or Not stated) and [mm:ss]. Otherwise "None".
    """
    static let mergePrompt = """
    You merge notes taken from consecutive parts of one meeting. Combine them into one set of notes with the same bullets-only layout (Topics, Decisions, Tasks). Remove duplicates and merge bullets about the same topic, but keep every distinct decision and task with its owner, due date and [mm:ss], and every name, number and date. Do not add anything and do not turn specifics into general statements. Keep any "Not a meeting" notes. No preamble.
    """
    static let chunkWords = 2500

    /// Explicit AI-settings choice if set and reachable, else Ollama if up, else Apple if ready, else none.
    static func resolve(explicit: LLMProvider?, explicitReady: Bool, ollamaUp: Bool, appleReady: Bool, appleSupportsLanguage: Bool = true) -> SummaryChoice {
        if let explicit, explicitReady { return .provider(explicit) }
        if ollamaUp { return .provider(.ollama) }
        if appleReady && appleSupportsLanguage { return .apple }
        return .none
    }

    /// Dominant language code ("en", "hi", …) of a transcript, nil when it can't tell.
    static func dominantLanguage(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage?.rawValue
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// Plain-English reason shown when Apple's model can't read the transcript and nothing else is set up.
    static func unsupportedReason(language code: String) -> String {
        "This transcript is mostly \(languageName(code)). Apple's on-device model only summarizes English and a few other languages. Install Ollama (https://ollama.com), run `ollama pull qwen3:8b`, and OpenWispr will use it automatically — or add an OpenAI/OpenRouter key in AI settings."
    }

    /// Reason to show instead of the generic setup text, or nil when the transcript language isn't the problem.
    static func noModelReason(for transcript: String) -> String? {
        guard AppleLocalEngine.isAvailable(), let lang = dominantLanguage(transcript),
              !AppleLocalEngine.supports(language: lang) else { return nil }
        return unsupportedReason(language: lang)
    }

    static func resolveLive(for transcript: String? = nil) async -> SummaryChoice {
        let lang = transcript.flatMap(dominantLanguage)
        return await resolveLive(appleOK: lang.map(AppleLocalEngine.supports(language:)) ?? true)
    }

    private static func resolveLive(appleOK: Bool) async -> SummaryChoice {
        let raw = UserDefaults.standard.string(forKey: "llmProvider")
        let explicit = raw.flatMap(LLMProvider.init(rawValue:))
        let ollama = await !LLMClient.ollamaModels().isEmpty   // running with no model pulled is not usable
        var ready = false
        if let explicit { ready = explicit == .ollama ? ollama : (LLMClient.apiKey(for: explicit)?.isEmpty == false) }
        return resolve(explicit: explicit, explicitReady: ready, ollamaUp: ollama, appleReady: AppleLocalEngine.isAvailable(), appleSupportsLanguage: appleOK)
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
        case .apple:
            do { return try await AppleLocalEngine.complete(system: system, user: user) }
            catch where String(describing: error).contains("unsupportedLanguageOrLocale") {
                // Apple rejected the language at runtime: retry once with Ollama / the keyed provider.
                let next = await resolveLive(appleOK: false)
                if next != .none { return try await call(next, system: system, user: user) }
                throw LLMError.badResponse(unsupportedReason(language: dominantLanguage(user) ?? "this language"))
            }
        case .provider(let p): return try await LLMClient.complete(system: system, user: user, using: p)
        case .none: throw LLMError.notConfigured
        }
    }

    /// "Meeting date: Monday, 16 November 2026." so the model can turn "by Friday" into a date.
    static func dateLine(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM yyyy"
        return "Meeting date: \(f.string(from: date)). Date table: \(dateTable(date))."
    }

    /// "today = Mon 16 Nov 2026; tomorrow = Tue 17 Nov 2026; Tue = 17 Nov 2026; ... next Mon = 23 Nov 2026" for the 13 days after `date`.
    static func dateTable(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        let cal = f.calendar!
        func fmt(_ d: Date, _ pattern: String) -> String { f.dateFormat = pattern; return f.string(from: d) }
        var out = ["today = \(fmt(date, "EEE d MMM yyyy"))"]
        for n in 1...13 {
            guard let d = cal.date(byAdding: .day, value: n, to: date) else { continue }
            if n == 1 { out.append("tomorrow = \(fmt(d, "EEE d MMM yyyy"))") }
            out.append("\(n >= 7 ? "next " : "")\(fmt(d, "EEE")) = \(fmt(d, "d MMM yyyy"))")
        }
        return out.joined(separator: "; ")
    }

    /// "[m:ss] Speaker: text" lines, the shape the prompts expect.
    static func transcriptText(_ lines: [MeetingLine]) -> String {
        lines.map { "[\(Int($0.start.rounded()) / 60):\(String(format: "%02d", Int($0.start.rounded()) % 60))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// Greedy groups of at least two consecutive items, each at most `maxWords` words (a lone oversized item still gets a group).
    static func group(_ items: [String], maxWords: Int) -> [[String]] {
        var out: [[String]] = []
        var cur: [String] = []
        var n = 0
        for it in items {
            let w = wordCount(it)
            if cur.count >= 2 && n + w > maxWords { out.append(cur); cur = []; n = 0 }
            cur.append(it); n += w
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Short transcripts go straight through. Long ones: extract notes per chunk, then merge and de-duplicate them
    /// into the final sections (no re-summarising). On the Apple model (~4k-token window) notes that don't fit
    /// are merged a few parts at a time first; a chunk that still overflows is retried at half size.
    static func summarize(transcript: String, choice: SummaryChoice, maxWords: Int = chunkWords, meetingDate: Date? = nil) async throws -> String {
        let head = meetingDate.map { dateLine($0) + "\n\n" } ?? ""
        let parts = chunk(transcript, maxWords: maxWords)
        if parts.count <= 1 {
            do { return try await call(choice, system: systemPrompt, user: head + transcript) }
            catch where choice == .apple && maxWords > 300 && wordCount(transcript) > 300 {
                return try await summarize(transcript: transcript, choice: choice, maxWords: max(300, wordCount(transcript) / 2), meetingDate: meetingDate)
            }
        }
        var notes: [String] = []
        for p in parts { notes.append(try await call(choice, system: partPrompt, user: head + p)) }
        if choice == .apple {
            var rounds = 0
            while notes.count > 1, notes.reduce(0, { $0 + wordCount($1) }) > maxWords, rounds < 4 {
                var merged: [String] = []
                for g in group(notes, maxWords: maxWords) {
                    merged.append(g.count == 1 ? g[0] : try await call(choice, system: mergePrompt, user: head + g.joined(separator: "\n\n")))
                }
                notes = merged; rounds += 1
            }
        }
        let joined = notes.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
        return try await call(choice, system: systemPrompt, user: head + joined)
    }

    static func selfTest() {
        typealias C = SummaryChoice
        precondition(resolve(explicit: .openai, explicitReady: true, ollamaUp: true, appleReady: true) == C.provider(.openai), "explicit ready must win")
        precondition(resolve(explicit: .openai, explicitReady: false, ollamaUp: true, appleReady: true) == C.provider(.ollama), "unready explicit falls to ollama")
        precondition(resolve(explicit: nil, explicitReady: false, ollamaUp: true, appleReady: true) == C.provider(.ollama), "ollama before apple")
        precondition(resolve(explicit: nil, explicitReady: false, ollamaUp: false, appleReady: true) == C.apple, "apple when alone")
        precondition(resolve(explicit: .openrouter, explicitReady: false, ollamaUp: false, appleReady: true) == C.apple, "apple after dead explicit")
        precondition(resolve(explicit: nil, explicitReady: false, ollamaUp: false, appleReady: false) == C.none, "none")
        precondition(resolve(explicit: nil, explicitReady: false, ollamaUp: false, appleReady: true, appleSupportsLanguage: false) == C.none, "apple skipped for unsupported language")
        precondition(resolve(explicit: nil, explicitReady: false, ollamaUp: true, appleReady: true, appleSupportsLanguage: false) == C.provider(.ollama), "ollama wins for unsupported language")
        print("SummaryEngine.resolve selfTest PASS (8 cases)")

        let langs = [("Let's review the launch plan and decide who owns the pricing page by Friday.", "en"),
                     ("आज हम लॉन्च की योजना पर बात करेंगे और तय करेंगे कि कीमत का पेज कौन बनाएगा।", "hi"),
                     ("aaj hum launch plan par baat karenge aur tay karenge ki pricing page kaun banayega", "hinglish"),
                     ("", "nil")]
        for (text, want) in langs {
            let got = dominantLanguage(text)
            switch want {
            case "nil": precondition(got == nil, "empty text → nil, got \(got ?? "")")
            case "hinglish": precondition(got != nil, "hinglish must detect something"); print("  hinglish detected as \(got!)")
            default: precondition(got == want, "expected \(want), got \(got ?? "nil")")
            }
        }
        print("SummaryEngine.dominantLanguage selfTest PASS (4 cases)")

        let line = Array(repeating: "word", count: 40).joined(separator: " ")
        let text = (0..<250).map { _ in "You: \(line)" }.joined(separator: "\n") // 250 * 41 = 10,250 words
        let chunks = chunk(text)
        precondition(chunks.count >= 4, "expected >=4 chunks, got \(chunks.count)")
        precondition(chunks.allSatisfy { wordCount($0) <= chunkWords }, "chunk over 2500 words")
        precondition(chunks.reduce(0) { $0 + wordCount($1) } == 10_250, "words lost in chunking")
        let one = chunk(Array(repeating: "w", count: 10_000).joined(separator: " "))
        precondition(one.count == 4 && one.allSatisfy { wordCount($0) <= chunkWords }, "single long line")
        print("SummaryEngine.chunk selfTest PASS (\(chunks.count) chunks of ≤\(chunkWords) words from 10,250; single line → \(one.count))")

        for h in ["## Topics discussed", "## Decisions", "## Action items", "Owner: <name or Unassigned> · Due: <date or Not stated>", "Unassigned", "Not stated", "Hinglish", "\"You\" is the local user"] {
            precondition(systemPrompt.contains(h), "systemPrompt missing \(h)")
        }
        precondition(!systemPrompt.contains("## Summary"), "old Summary heading still in prompt")
        precondition(partPrompt.contains("[mm:ss]") && partPrompt.contains("Not a meeting") && mergePrompt.contains("every distinct decision"), "part/merge prompt incomplete")
        let order = ["## Topics discussed", "## Decisions", "## Action items"].compactMap { systemPrompt.range(of: $0)?.lowerBound }
        precondition(order.count == 3 && order == order.sorted(), "heading order")
        precondition(!systemPrompt.contains("Markdown table"), "table instruction still in prompt")
        let fixed = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!
        precondition(dateLine(fixed).hasPrefix("Meeting date: Monday, 16 November 2026."), "dateLine got \(dateLine(fixed))")
        let table = dateTable(fixed)
        for k in ["tomorrow = Tue 17 Nov 2026", "Wed = 18 Nov 2026", "Fri = 20 Nov 2026", "next Mon = 23 Nov 2026"] { precondition(table.contains(k), "dateTable missing \(k)") }
        let keys = table.components(separatedBy: "; ").map { $0.components(separatedBy: " = ")[0] }
        precondition(Set(keys).count == keys.count, "dateTable duplicate keys")
        let ml = [MeetingLine(speaker: "You", text: "hi", start: 65, end: 66)]
        precondition(transcriptText(ml) == "[1:05] You: hi", "transcriptText got \(transcriptText(ml))")
        let items = (0..<7).map { "Part \($0) " + Array(repeating: "w", count: 40 + $0).joined(separator: " ") }
        for cap in [1, 50, 100, 10_000] {
            let g = group(items, maxWords: cap)
            precondition(Array(g.joined()) == items, "group lost or reordered parts at cap \(cap)")
            precondition(g.dropLast().allSatisfy { $0.count >= 2 }, "group smaller than 2 at cap \(cap)")
        }
        precondition(group(items, maxWords: 100).count < items.count, "group made no progress")
        print("SummaryEngine.prompts/date/group selfTest PASS")
    }
}
