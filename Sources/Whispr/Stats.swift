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
        persist()
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
        persist()
    }

    static func noteFixAccepted(_ n: Int = 1) {
        d.set(fixesAccepted + n, forKey: "fixesAccepted")
        persist()
    }

    // MARK: - Durable mirror (Application Support survives app deletion + a defaults wipe; UserDefaults doesn't)

    struct Snapshot: Codable {
        var lifetimeWords: Int
        var lifetimeSeconds: Double
        var lifetimeDictations: Int
        var fixesAccepted: Int
        var meetingsCount: Int
        var dailyWords: [String: Int]
        var appWords: [String: Int]
    }

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("stats.json")
    }()

    static func snapshot() -> Snapshot {
        Snapshot(lifetimeWords: lifetimeWords, lifetimeSeconds: lifetimeSeconds,
                 lifetimeDictations: lifetimeDictations, fixesAccepted: fixesAccepted,
                 meetingsCount: d.integer(forKey: "meetingsCount"),
                 dailyWords: dailyWords, appWords: appWords)
    }

    static func apply(_ s: Snapshot) {
        d.set(s.lifetimeWords, forKey: "lifetimeWords")
        d.set(s.lifetimeSeconds, forKey: "lifetimeSeconds")
        d.set(s.lifetimeDictations, forKey: "lifetimeDictations")
        d.set(s.fixesAccepted, forKey: "fixesAccepted")
        d.set(s.meetingsCount, forKey: "meetingsCount")
        dailyWords = s.dailyWords
        appWords = s.appWords
    }

    private static func persist() {
        if let data = try? JSONEncoder().encode(snapshot()) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Fresh defaults + a mirror on disk → restore; otherwise export so existing users get a file immediately.
    /// Never overwrites non-empty defaults from the file.
    static func syncOnLaunch() {
        if d.object(forKey: "lifetimeWords") == nil,
           let data = try? Data(contentsOf: fileURL),
           let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            apply(s)
        } else if lifetimeWords > 0 {
            persist()
        }
    }

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

    /// Driven by `core/fixtures/stats.json`, the same table the Rust port is held to.
    /// Dates are expressed as `daysAgo` offsets so the cases never go stale.
    struct FixtureFile: Decodable {
        struct HoursCase: Decodable {
            let typingHoursPerDay: Double
            let expected: Double
        }
        struct EntrySpec: Decodable {
            let daysAgo: Int
            let text: String
            let seconds: Double?
        }
        struct StreakCase: Decodable {
            let entries: [EntrySpec]
            let expected: Int
        }
        struct SavedCase: Decodable {
            let words: Int
            let wpm: Int
            let typingWpm: Int?
            let expected: Double
        }
        struct HeatCase: Decodable {
            let words: Int
            let max: Int
            let expected: Int
        }
        struct SeriesCase: Decodable {
            let days: Int
            let mapDaysAgo: [String: Int]
            let expectedLen: Int
            let expectedFirst: Int
            let expectedLast: Int
        }
        struct LongestCase: Decodable {
            let daysAgo: [Int]
            let expected: Int
        }
        let hoursSavedPerWeek: [HoursCase]
        let streak: [StreakCase]
        let avgWpm: [StreakCase]
        let timeSavedMinutes: [SavedCase]
        let heatBucket: [HeatCase]
        let dailySeries: [SeriesCase]
        let longestStreak: [LongestCase]
    }

    private static func entries(_ specs: [FixtureFile.EntrySpec], now: Date) -> [HistoryEntry] {
        let cal = Calendar.current
        return specs.map {
            HistoryEntry(date: cal.date(byAdding: .day, value: -$0.daysAgo, to: now)!,
                         text: $0.text, seconds: $0.seconds)
        }
    }

    static func selfTest() {
        let f = Fixtures.load(FixtureFile.self, "stats.json")
        let cal = Calendar.current
        let now = Date()
        let key = { (back: Int) in dayKey(cal.date(byAdding: .day, value: -back, to: now)!) }

        for c in f.streak {
            Fixtures.expectEqual(streak(entries: entries(c.entries, now: now), now: now), c.expected, "streak")
        }
        for c in f.avgWpm {
            Fixtures.expectEqual(avgWPM(entries: entries(c.entries, now: now)), c.expected, "avgWPM")
        }
        for c in f.timeSavedMinutes {
            let got = timeSavedMinutes(words: c.words, wpm: c.wpm, typingWPM: c.typingWpm ?? 40)
            Fixtures.expectClose(got, c.expected, "timeSavedMinutes(\(c.words), \(c.wpm))")
        }
        for c in f.heatBucket {
            Fixtures.expectEqual(heatBucket(words: c.words, max: c.max), c.expected, "heatBucket")
        }
        for c in f.dailySeries {
            var map: [String: Int] = [:]
            for (back, words) in c.mapDaysAgo { map[key(Int(back)!)] = words }
            let series = dailySeries(days: c.days, now: now, map: map)
            Fixtures.expectEqual(series.count, c.expectedLen, "dailySeries length")
            Fixtures.expectEqual(series.first?.words ?? -1, c.expectedFirst, "dailySeries oldest")
            Fixtures.expectEqual(series.last?.words ?? -1, c.expectedLast, "dailySeries newest")
        }
        for c in f.longestStreak {
            var map: [String: Int] = [:]
            for back in c.daysAgo { map[key(back)] = 5 }
            Fixtures.expectEqual(longestStreak(map: map), c.expected, "longestStreak")
        }
        // Snapshot round-trip (in-memory only — no file I/O in the selftest)
        let snap = Snapshot(lifetimeWords: 1234, lifetimeSeconds: 567.8, lifetimeDictations: 42,
                            fixesAccepted: 7, meetingsCount: 3,
                            dailyWords: ["2026-01-01": 10, "2026-01-02": 20],
                            appWords: ["com.apple.Notes": 30])
        if let data = try? JSONEncoder().encode(snap),
           let back = try? JSONDecoder().decode(Snapshot.self, from: data) {
            Fixtures.expectEqual(back.lifetimeWords, snap.lifetimeWords, "snapshot lifetimeWords")
            Fixtures.expectClose(back.lifetimeSeconds, snap.lifetimeSeconds, "snapshot lifetimeSeconds")
            Fixtures.expectEqual(back.lifetimeDictations, snap.lifetimeDictations, "snapshot lifetimeDictations")
            Fixtures.expectEqual(back.fixesAccepted, snap.fixesAccepted, "snapshot fixesAccepted")
            Fixtures.expectEqual(back.meetingsCount, snap.meetingsCount, "snapshot meetingsCount")
            Fixtures.expectEqual(back.dailyWords, snap.dailyWords, "snapshot dailyWords")
            Fixtures.expectEqual(back.appWords, snap.appWords, "snapshot appWords")
        } else {
            Fixtures.expectEqual(false, true, "snapshot round-trip encode/decode")
        }

        print("Stats.selfTest PASS (\(f.streak.count + f.avgWpm.count + f.timeSavedMinutes.count) cases)")
    }
}
