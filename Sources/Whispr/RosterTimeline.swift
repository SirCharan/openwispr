import Foundation

/// (meeting-clock seconds, who the meeting UI marks as speaking), shared by the Zoom AX reader
/// and the Meet extension listener. Maps those names onto diarized speakers at Stop.
@MainActor
final class RosterTimeline {
    private(set) var samples: [(t: TimeInterval, name: String)] = []
    private(set) var roster: Set<String> = []

    func reset() { samples.removeAll(); roster.removeAll() }

    func record(t: TimeInterval, names: [String], speaking: [String]) {
        roster.formUnion(names)
        for s in speaking { samples.append((t, s)) }
    }

    func names(forDiarized segments: [Diarizer.Segment]) -> [String: String] {
        Self.map(segments: segments, timeline: samples)
    }

    /// Pure. For each diarized speaker, the dominant roster name if it covers ≥60% of the
    /// speaker's talk time (each timeline sample ≈ 1-2 s). A name is given to one speaker only.
    nonisolated static func map(segments: [Diarizer.Segment], timeline: [(t: TimeInterval, name: String)]) -> [String: String] {
        var talk: [String: Double] = [:]
        var votes: [String: [String: Double]] = [:]
        for s in segments {
            talk[s.speaker, default: 0] += s.end - s.start
            for p in timeline where p.t >= s.start && p.t < s.end { votes[s.speaker, default: [:]][p.name, default: 0] += 1 }
        }
        var best: [(speaker: String, name: String, share: Double)] = []
        for (sp, v) in votes {
            guard let top = v.max(by: { $0.value < $1.value }), let total = talk[sp], total > 0 else { continue }
            let share = top.value / total
            if share >= 0.6 { best.append((sp, top.key, share)) }
        }
        var out: [String: String] = [:]
        for b in best.sorted(by: { $0.share > $1.share }) where !out.values.contains(b.name) { out[b.speaker] = b.name }
        return out
    }

    static func selfTest() {
        let segs = [Diarizer.Segment(speaker: "Speaker A", start: 0, end: 10),
                    Diarizer.Segment(speaker: "Speaker B", start: 10, end: 20)]
        var tl: [(t: TimeInterval, name: String)] = (0..<8).map { (TimeInterval($0), "Asha") }
        tl += (10..<14).map { (TimeInterval($0), "Ben") } // 4 of 10 s: below 60%
        let m = map(segments: segs, timeline: tl)
        precondition(m == ["Speaker A": "Asha"], "dominant ≥60% only: \(m)")
        // Meet-shaped: roster posts every second with a speaking flag; "You" stays "You".
        let r = RosterTimeline()
        for t in 0..<20 {
            let rahul = t < 9 || t == 12
            r.record(t: TimeInterval(t), names: ["You", "Rahul", "Priya"], speaking: rahul ? ["Rahul"] : (t < 19 ? ["Priya"] : []))
        }
        precondition(r.roster == ["You", "Rahul", "Priya"], "roster")
        let mm = r.names(forDiarized: segs)
        precondition(mm == ["Speaker A": "Rahul", "Speaker B": "Priya"], "meet map: \(mm)")
        print("RosterTimeline.selfTest PASS")
    }
}
