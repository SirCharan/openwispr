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

    // MARK: - Lifetime aggregates (survive the 200-entry history cap + "Clear history")

    private static let d = UserDefaults.standard
    static var lifetimeWords: Int { d.integer(forKey: "lifetimeWords") }
    static var lifetimeSeconds: Double { d.double(forKey: "lifetimeSeconds") }
    static var lifetimeDictations: Int { d.integer(forKey: "lifetimeDictations") }
    static var fixesAccepted: Int { d.integer(forKey: "fixesAccepted") }

    /// words per day, keyed "yyyy-MM-dd" — powers the heatmap + per-day chart independent of history.
    static var dailyWords: [String: Int] {
        get { (d.dictionary(forKey: "dailyWords") as? [String: Int]) ?? [:] }
        set {
            var v = newValue
            if v.count > 400, let cut = v.keys.sorted().dropLast(400).first {   // keep ~400 days
                v = v.filter { $0.key >= cut }
            }
            d.set(v, forKey: "dailyWords")
        }
    }

    /// words per app bundle id (forward-only, from v0.14).
    static var appWords: [String: Int] {
        get { (d.dictionary(forKey: "appWords") as? [String: Int]) ?? [:] }
        set { d.set(newValue, forKey: "appWords") }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar.current
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// One dictation: roll into every aggregate.
    static func record(words: Int, seconds: Double?, appBundleID: String?, now: Date = Date()) {
        guard words > 0 else { return }
        d.set(lifetimeWords + words, forKey: "lifetimeWords")
        d.set(lifetimeSeconds + (seconds ?? 0), forKey: "lifetimeSeconds")
        d.set(lifetimeDictations + 1, forKey: "lifetimeDictations")
        var day = dailyWords
        day[dayKey(now), default: 0] += words
        dailyWords = day
        if let id = appBundleID {
            var apps = appWords
            apps[id, default: 0] += words
            appWords = apps
        }
    }

    static func noteFixAccepted(_ n: Int = 1) { d.set(fixesAccepted + n, forKey: "fixesAccepted") }

    // MARK: - Derived (pure, self-tested)

    /// Minutes saved vs typing: same words at `typingWPM` minus the time you actually spoke.
    static func timeSavedMinutes(words: Int, wpm: Int, typingWPM: Int = 40) -> Double {
        guard words > 0, typingWPM > 0 else { return 0 }
        let speak = wpm > 0 ? Double(words) / Double(wpm) : 0
        return max(0, Double(words) / Double(typingWPM) - speak)
    }

    /// Heat intensity 0…4 for the streak grid.
    static func heatBucket(words: Int, max maxWords: Int) -> Int {
        guard words > 0, maxWords > 0 else { return 0 }
        let r = Double(words) / Double(maxWords)
        if r > 0.66 { return 4 }
        if r > 0.33 { return 3 }
        if r > 0.10 { return 2 }
        return 1
    }

    /// Last `days` days (oldest → newest) as (date, words), zero-filled.
    static func dailySeries(days: Int, now: Date = Date(), map: [String: Int]? = nil) -> [(date: Date, words: Int)] {
        let m = map ?? dailyWords
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<days).reversed().compactMap { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (day, m[dayKey(day)] ?? 0)
        }
    }

    /// Longest run of consecutive active days in `dailyWords`.
    static func longestStreak(map: [String: Int]? = nil) -> Int {
        let keys = (map ?? dailyWords).filter { $0.value > 0 }.keys.sorted()
        guard !keys.isEmpty else { return 0 }
        let cal = Calendar.current
        var best = 1, run = 1
        for i in 1..<keys.count {
            guard let a = dayFormatter.date(from: keys[i - 1]), let b = dayFormatter.date(from: keys[i]) else { continue }
            let gap = cal.dateComponents([.day], from: a, to: b).day ?? 0
            run = gap == 1 ? run + 1 : 1
            best = max(best, run)
        }
        return best
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

        // time saved: 400 words at 100 wpm spoken = 4 min; typed at 40 wpm = 10 min → 6 saved
        assert(abs(timeSavedMinutes(words: 400, wpm: 100) - 6) < 0.001, "timeSaved wrong")
        assert(timeSavedMinutes(words: 0, wpm: 100) == 0, "timeSaved empty wrong")
        assert(timeSavedMinutes(words: 100, wpm: 10) == 0, "slower-than-typing should floor at 0")
        // heat buckets
        assert(heatBucket(words: 0, max: 100) == 0 && heatBucket(words: 5, max: 100) == 1
               && heatBucket(words: 50, max: 100) == 3 && heatBucket(words: 100, max: 100) == 4, "heatBucket wrong")
        // series is zero-filled, oldest first, right length
        let series = dailySeries(days: 3, now: now, map: [dayKey(now): 12])
        assert(series.count == 3 && series.last?.words == 12 && series.first?.words == 0, "dailySeries wrong")
        // longest streak across a gap
        let k = { (back: Int) in dayKey(cal.date(byAdding: .day, value: -back, to: now)!) }
        assert(longestStreak(map: [k(0): 5, k(1): 5, k(2): 5, k(9): 5]) == 3, "longestStreak wrong")
        print("Stats.selfTest PASS")
    }
}
