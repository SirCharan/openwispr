import Foundation

/// (meeting-clock seconds, who the meeting UI marks as speaking), shared by the Zoom AX reader
/// and the Meet extension listener. Maps those names onto diarized speakers at Stop.
@MainActor
final class RosterTimeline {
    private(set) var samples: [(t: TimeInterval, name: String)] = []
    private(set) var roster: Set<String> = []
    /// One entry per roster post: who was speaking at `t` (may be empty). Held for ≤ `holdSeconds`.
    private(set) var states: [(t: TimeInterval, speaking: Set<String>)] = []
    /// The local user's name in the roster, once the source flagged it (Meet extension `self: true`).
    private(set) var selfName: String?

    func reset() { samples.removeAll(); roster.removeAll(); states.removeAll(); selfName = nil }

    func record(t: TimeInterval, names: [String], speaking: [String], selfName: String? = nil) {
        roster.formUnion(names)
        for s in speaking { samples.append((t, s)) }
        states.append((t, Set(speaking)))
        if let selfName { self.selfName = selfName }
    }

    /// Label for one transcript line, or nil when the window is ambiguous.
    func label(start: TimeInterval, end: TimeInterval, mic: Bool, echoLikely: Bool = false) -> String? {
        Self.lineLabel(states: states, selfName: selfName, start: start, end: end, mic: mic, echoLikely: echoLikely)
    }

    nonisolated static let holdSeconds = 6.0

    /// Pure. Per name: share of [start, end] it was shown speaking (each state holds until the next
    /// post, at most `holdSeconds`) and how many states contributed.
    nonisolated static func windowShares(states: [(t: TimeInterval, speaking: Set<String>)], start: TimeInterval, end: TimeInterval) -> (share: [String: Double], count: [String: Int]) {
        var share: [String: Double] = [:], count: [String: Int] = [:]
        let len = end - start
        guard len > 0 else { return (share, count) }
        for (i, s) in states.enumerated() {
            let until = min(i + 1 < states.count ? states[i + 1].t : .infinity, s.t + holdSeconds)
            let lo = max(s.t, start), hi = min(until, end)
            guard hi > lo else { continue }
            for n in s.speaking { share[n, default: 0] += (hi - lo) / len; count[n, default: 0] += 1 }
        }
        return (share, count)
    }

    /// Pure. A remote name needs a clear majority (≥50% of the window, no tie, ≥2 states) and the local
    /// user must not be the louder side. A mic line (`mic`) is only relabelled when it is a likely echo of
    /// the call (`echoLikely`), `selfName` is known and the local user was silent (≤10%) in the window.
    /// Meet's self tile stays dark while the user is muted, so silence alone never proves the words are not theirs.
    nonisolated static func lineLabel(states: [(t: TimeInterval, speaking: Set<String>)], selfName: String?, start: TimeInterval, end: TimeInterval, mic: Bool, echoLikely: Bool = false) -> String? {
        if mic && (selfName == nil || !echoLikely) { return nil }
        let w = windowShares(states: states, start: start, end: end)
        let remote = w.share.filter { $0.key != "You" && $0.key != selfName }
        guard let top = remote.max(by: { $0.value < $1.value }),
              top.value >= 0.5, (w.count[top.key] ?? 0) >= 2,
              !remote.contains(where: { $0.key != top.key && $0.value >= top.value }) else { return nil }
        let me = selfName.flatMap { w.share[$0] } ?? w.share["You"] ?? 0
        if mic ? me > 0.1 : me >= top.value { return nil }
        return top.key
    }

    /// Pure. A mic line is a likely echo when a system-origin line overlaps it, or the system stream was
    /// down or silent for ≥80% of its window (`quietSpans` are disjoint meeting-clock spans).
    nonisolated static func micLineLooksEcho(start: TimeInterval, end: TimeInterval, quietSpans: [(TimeInterval, TimeInterval)],
                                             systemLines: [(TimeInterval, TimeInterval)]) -> Bool {
        if systemLines.contains(where: { $0.0 < end && start < $0.1 }) { return true }
        let len = end - start
        guard len > 0 else { return false }
        let quiet = quietSpans.reduce(0.0) { $0 + max(0, min($1.1, end) - max($1.0, start)) }
        return quiet / len >= 0.8
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
        // Per-line majority: Rahul speaks to t=8 (and t=12), Priya takes over.
        precondition(r.label(start: 1, end: 6, mic: false) == "Rahul", "line majority")
        precondition(r.label(start: 11, end: 17, mic: false) == "Priya", "line majority 2")
        // Ambiguous: window 6-14 splits 4 s / 4 s, so the label is left alone.
        precondition(r.label(start: 6, end: 14, mic: false) == nil, "ambiguous window stays nil")
        // One sample is not enough.
        let one = RosterTimeline(); one.record(t: 0, names: ["Rahul"], speaking: ["Rahul"])
        precondition(Self.lineLabel(states: one.states, selfName: nil, start: 0, end: 1, mic: false) == nil, "needs 2 states")
        // Mic fallback: needs a self flag, remote speaking, local silent.
        let m2 = RosterTimeline()
        for t in 0..<10 { m2.record(t: TimeInterval(t), names: ["You", "Rahul"], speaking: ["Rahul"], selfName: "You") }
        precondition(m2.label(start: 1, end: 8, mic: true, echoLikely: true) == "Rahul", "mic line carries remote speaker")
        precondition(m2.label(start: 1, end: 8, mic: true) == nil, "muted-in-Meet user: healthy system, no overlap, stays You")
        precondition(m2.label(start: 1, end: 8, mic: false) == "Rahul", "remote line")
        let m3 = RosterTimeline() // no self flag: mic lines untouched
        for t in 0..<10 { m3.record(t: TimeInterval(t), names: ["You", "Rahul"], speaking: ["Rahul"]) }
        precondition(m3.label(start: 1, end: 8, mic: true, echoLikely: true) == nil, "no self flag, no mic relabel")
        let m4 = RosterTimeline() // user also speaking: stays You
        for t in 0..<10 { m4.record(t: TimeInterval(t), names: ["You", "Rahul"], speaking: t < 5 ? ["Rahul", "You"] : ["Rahul"], selfName: "You") }
        precondition(m4.label(start: 0, end: 9, mic: true, echoLikely: true) == nil, "local speaking keeps You")
        precondition(micLineLooksEcho(start: 10, end: 14, quietSpans: [], systemLines: [(12, 16)]), "overlapping system line is an echo")
        precondition(!micLineLooksEcho(start: 10, end: 14, quietSpans: [], systemLines: [(20, 24)]), "no overlap, healthy system: not an echo")
        precondition(micLineLooksEcho(start: 10, end: 14, quietSpans: [(0, 11), (11.5, 30)], systemLines: []), "system down/silent window is an echo")
        precondition(!micLineLooksEcho(start: 10, end: 14, quietSpans: [(0, 11)], systemLines: []), "mostly-live system window is not an echo")
        print("RosterTimeline.selfTest PASS")
    }
}
