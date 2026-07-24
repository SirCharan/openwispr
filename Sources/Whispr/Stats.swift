import Foundation

/// Home-window stats derived from history (Muesli-style: streak · words · avg WPM · meetings).
enum Stats {
    struct Summary {
        var streakDays: Int
        var totalWords: Int
        var avgWPM: Int
        var meetings: Int
    }

    static func summary(entries: [HistoryEntry] = HistoryStore.load(), now: Date = Date()) -> Summary {
        Summary(
            streakDays: streak(entries: entries, now: now),
            totalWords: entries.reduce(0) { $0 + $1.words },
            avgWPM: avgWPM(entries: entries),
            meetings: UserDefaults.standard.integer(forKey: "meetingsCount")
        )
    }

    /// Consecutive days ending today (or yesterday, so an unused morning doesn't zero it) with ≥1 entry.
    static func streak(entries: [HistoryEntry], now: Date = Date()) -> Int {
        guard !entries.isEmpty else { return 0 }
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: $0.date) })
        var cursor = cal.startOfDay(for: now)
        if !days.contains(cursor) {
            guard let y = cal.date(byAdding: .day, value: -1, to: cursor), days.contains(y) else { return 0 }
            cursor = y
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    /// Words per minute over entries that recorded a duration; 0 when none have.
    static func avgWPM(entries: [HistoryEntry]) -> Int {
        let timed = entries.filter { ($0.seconds ?? 0) > 1 }
        let words = timed.reduce(0) { $0 + $1.words }
        let minutes = timed.reduce(0.0) { $0 + ($1.seconds ?? 0) } / 60
        guard minutes > 0 else { return 0 }
        return Int((Double(words) / minutes).rounded())
    }

    static func recordMeeting() {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "meetingsCount") + 1, forKey: "meetingsCount")
    }

    static func selfTest() {
        let cal = Calendar.current
        let now = Date()
        let today = HistoryEntry(text: "one two three", seconds: 3)
        let yest = HistoryEntry(date: cal.date(byAdding: .day, value: -1, to: now)!, text: "four five", seconds: 60)
        let gap = HistoryEntry(date: cal.date(byAdding: .day, value: -5, to: now)!, text: "six")
        assert(streak(entries: [today, yest, gap], now: now) == 2, "streak wrong")
        assert(streak(entries: [gap], now: now) == 0, "gap streak should be 0")
        assert(avgWPM(entries: [yest]) == 2, "wpm wrong: \(avgWPM(entries: [yest]))")
        print("Stats.selfTest PASS")
    }
}
