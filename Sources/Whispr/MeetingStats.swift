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
    /// English-only on purpose: Hindi/Hinglish fillers are not covered and are tokenised like any
    /// other word. Multi-word entries ("you know") are matched as word pairs.
    static let fillers: Set<String> = ["um", "uh", "hmm", "like", "you know", "basically", "actually", "so", "right", "okay"]

    var date = Date()
    var you = "You"                  // the mic speaker's current label (renamed at stop)
    var duration = 0.0
    var speakers: [Speaker] = []
    var questionsPerHour = 0.0
    var fillersPerMinute = 0.0
    var interruptions: Int { speakers.reduce(0) { $0 + $1.interruptions } }

    /// Letters and apostrophes only, lowercased; Devanagari and other scripts survive as words.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    static func compute(segments: [Diarizer.Segment], lines: [MeetingLine], date: Date = Date(), you: String = "You") -> MeetingStats {
        let segs = segments.sorted { $0.start < $1.start }
        let begin = min(segs.first?.start ?? .infinity, lines.map(\.start).min() ?? .infinity)
        let end = max(segs.map(\.end).max() ?? 0, lines.map(\.end).max() ?? 0)
        let duration = begin.isFinite ? max(0, end - begin) : 0

        // Merge consecutive same-speaker segments into turns.
        var turns: [(speaker: String, start: Double, end: Double)] = []
        var talk: [String: Double] = [:]
        for s in segs {
            talk[s.speaker, default: 0] += max(0, s.end - s.start)
            if let last = turns.last, last.speaker == s.speaker {
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
            if l.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { questions += 1 }
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
        return MeetingStats(date: date, you: you, duration: duration, speakers: speakers,
                            questionsPerHour: duration > 0 ? Double(questions) / (duration / 3600) : 0,
                            fillersPerMinute: duration > 0 ? Double(fillerCount) / (duration / 60) : 0)
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
        print("MeetingStats.selfTest PASS")
    }
}
