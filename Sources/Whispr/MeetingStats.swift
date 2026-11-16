import Foundation

/// Per-meeting analytics, computed from diarization segments plus transcript lines.
struct MeetingStats: Codable, Equatable {
    struct Speaker: Codable, Equatable {
        var name: String
        var talkSeconds: Double
        var sharePct: Double
        var words: Int
        var wpm: Double              // words per minute of the speaker's own speech time
        var turns: Int
        var longestMonologue: Double // seconds, consecutive same-speaker segments merged
        var interruptions: Int       // times this speaker started while another was still talking
        var longMonologue: Bool { longestMonologue >= MeetingStats.monologueFlag }
    }

    static let monologueFlag = 90.0
    /// Silence longer than this between same-speaker segments ends the turn.
    static let turnGap = 2.0
    /// English-only on purpose: Hindi/Hinglish fillers are not covered and are tokenised like any
    /// other word. Multi-word entries ("you know") are matched as word pairs.
    static let fillers: Set<String> = ["um", "uh", "hmm", "you know", "basically", "actually"]

    var date = Date()
    var you = "You"                  // the mic speaker's current label (renamed at stop)
    var duration = 0.0               // recorded: wall clock, first start to last end
    var active: Double?              // union of all speech segments; nil in stats saved before it existed
    var recorded: Double { duration }
    var activeOrRecorded: Double { (active ?? 0) > 0 ? active! : duration }
    var speakers: [Speaker] = []
    var questionsPerHour = 0.0
    var fillersPerMinute = 0.0
    var interruptions: Int { speakers.reduce(0) { $0 + $1.interruptions } }
    var interruptionsPerHour: Double { activeOrRecorded > 0 ? Double(interruptions) / (activeOrRecorded / 3600) : 0 }

    /// Sentences ending in "?": a run of question marks followed by whitespace or the end of the line.
    static func questionCount(_ text: String) -> Int {
        let c = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return c.indices.filter { i in
            guard c[i] == "?", i == c.count - 1 || c[i + 1] != "?" else { return false }
            return i == c.count - 1 || c[i + 1].isWhitespace || "\"')”’!".contains(c[i + 1])
        }.count
    }

    /// Letters and apostrophes only, lowercased; Devanagari and other scripts survive as words.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    static func compute(segments: [Diarizer.Segment], lines: [MeetingLine], date: Date = Date(), you: String = "You") -> MeetingStats {
        let segs = segments.sorted { $0.start < $1.start }
        let begin = min(segs.first?.start ?? .infinity, lines.map(\.start).min() ?? .infinity)
        let end = max(segs.map(\.end).max() ?? 0, lines.map(\.end).max() ?? 0)
        let duration = begin.isFinite ? max(0, end - begin) : 0

        // Active time: length of the union of all speech segments.
        var active = 0.0, reach = -Double.infinity
        for s in segs where s.end > s.start {
            active += max(0, s.end - max(s.start, reach))
            reach = max(reach, s.end)
        }

        // Merge consecutive same-speaker segments into turns, split at long silences.
        var turns: [(speaker: String, start: Double, end: Double)] = []
        var talk: [String: Double] = [:]
        for s in segs {
            talk[s.speaker, default: 0] += max(0, s.end - s.start)
            if let last = turns.last, last.speaker == s.speaker, s.start - last.end <= turnGap {
                turns[turns.count - 1].end = max(last.end, s.end)
            } else {
                turns.append((s.speaker, s.start, s.end))
            }
        }
        var interruptions: [String: Int] = [:]
        for (i, s) in segs.enumerated() where segs[..<i].contains(where: { $0.speaker != s.speaker && $0.start < s.start && s.start < $0.end }) {
            interruptions[s.speaker, default: 0] += 1
        }

        var words: [String: Int] = [:]
        var questions = 0, fillerCount = 0
        for l in lines {
            let t = tokens(l.text)
            words[l.speaker, default: 0] += t.count
            questions += questionCount(l.text)
            for (i, w) in t.enumerated() {
                if fillers.contains(w) { fillerCount += 1 }
                else if i > 0, t[i - 1] == w { fillerCount += 1 } // stutter: same word twice in a row
                if i > 0, fillers.contains(t[i - 1] + " " + w) { fillerCount += 1 }
            }
        }

        let total = talk.values.reduce(0, +)
        let names = Set(talk.keys).union(words.keys).sorted { (talk[$0] ?? 0) > (talk[$1] ?? 0) }
        let speakers = names.map { n -> Speaker in
            let secs = talk[n] ?? 0
            let mine = turns.filter { $0.speaker == n }
            return Speaker(name: n, talkSeconds: secs, sharePct: total > 0 ? secs / total * 100 : 0,
                           words: words[n] ?? 0, wpm: secs > 0 ? Double(words[n] ?? 0) / (secs / 60) : 0,
                           turns: mine.count, longestMonologue: mine.map { $0.end - $0.start }.max() ?? 0,
                           interruptions: interruptions[n] ?? 0)
        }
        let basis = active > 0 ? active : duration
        return MeetingStats(date: date, you: you, duration: duration, active: active, speakers: speakers,
                            questionsPerHour: basis > 0 ? Double(questions) / (basis / 3600) : 0,
                            fillersPerMinute: basis > 0 ? Double(fillerCount) / (basis / 60) : 0)
    }
}

/// Stats live beside the transcript: `meeting-<stamp>.md` -> `meeting-<stamp>.stats.json`.
enum MeetingStatsStore {
    static func url(for transcript: URL) -> URL { transcript.deletingPathExtension().appendingPathExtension("stats.json") }

    static func save(_ s: MeetingStats, transcript: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(s).write(to: url(for: transcript), options: .atomic)
    }

    /// Number of `*.stats.json` files (meetings that have stats, vs `meetingsCount`).
    static func fileCount() -> Int {
        let dir = MeetingArchive.directory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(".stats.json") }.count
    }

    static func loadAll() -> [MeetingStats] {
        let dir = MeetingArchive.directory
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(".stats.json") }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? dec.decode(MeetingStats.self, from: $0) } }
    }
}

extension MeetingStats {
    static func selfTest() {
        func seg(_ s: String, _ a: Double, _ b: Double) -> Diarizer.Segment { .init(speaker: s, start: a, end: b) }
        let m = compute(segments: [seg("A", 0, 10), seg("B", 5, 15)], lines: [MeetingLine(speaker: "A", text: "um um नमस्ते?", start: 0, end: 10)])
        precondition(abs(m.speakers.map(\.sharePct).reduce(0, +) - 100) < 0.001, "MeetingStats share failed")
        precondition(m.interruptions == 1, "MeetingStats interruptions failed")
        let f = realisticFixture()
        let you = f.speakers.first { $0.name == "You" }!
        precondition(abs(you.longestMonologue - 20) < 0.001 && you.turns == 3, "MeetingStats gap split failed")
        precondition(abs(f.recorded - 2900) < 0.001 && abs((f.active ?? 0) - 96) < 0.001, "MeetingStats active failed")
        precondition((f.speakers.first { $0.name == "Others" }?.sharePct ?? 0) > 0, "MeetingStats remote share failed")
        precondition(compute(segments: [], lines: [MeetingLine(speaker: "A", text: "Why? And how? Fine.", start: 0, end: 5)]).questionsPerHour > 0 &&
                     questionCount("Why? And how? Fine.") == 2, "MeetingStats questions failed")
        print("MeetingStats.selfTest PASS")
    }

    /// Shaped like a real session: a 40-minute gap, remote blips, an uncovered remote line, a two-question line.
    static func realisticFixture() -> MeetingStats {
        func seg(_ s: String, _ a: Double, _ b: Double) -> Diarizer.Segment { .init(speaker: s, start: a, end: b) }
        let segs = [seg("You", 0, 20), seg("You", 25, 30), seg("You", 2430, 2450), seg("A", 10, 11), seg("A", 2440, 2441.5),
                    seg("A", 2800, 2801), seg("Others", 2850, 2900)]
        let lines = [MeetingLine(speaker: "You", text: "Where are we? What next? Okay.", start: 0, end: 30),
                     MeetingLine(speaker: "Others", text: "Sounds good to me", start: 2850, end: 2900)]
        return compute(segments: segs, lines: lines)
    }
}
