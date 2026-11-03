import SwiftUI
import AppKit

/// Insights: WPM gauge, fixes, lifetime words + time saved, per-app usage, streak heatmap, words/day.
/// Everything here is derived from real local data (Stats aggregates) — no invented ranks or percentiles.
struct InsightsPane: View {
    @State private var daily: [String: Int] = [:]
    @State private var apps: [AppRow] = []
    @State private var meetings: [MeetingStats] = []

    @State private var overview = Stats.overview()
    private var wpm: Int { overview.avgWPM }
    private var words: Int { overview.lifetimeWords }
    private var savedHours: Double { overview.hoursSaved }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.s16) {
                topTiles
                perDayCard
                meetingsCard
                HStack(alignment: .top, spacing: Brand.s12) {
                    appsCard
                    heatmapCard
                }
            }
            .padding(Brand.s24)
            .padding(.bottom, Brand.s32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Brand.bg)
        .onAppear(perform: load)
    }

    private func load() {
        overview = Stats.overview()
        daily = Stats.dailyWords
        meetings = MeetingStatsStore.loadAll()
        apps = Stats.appWords
            .map { AppRow.resolve(bundleID: $0.key, words: $0.value) }
            .sorted { $0.words > $1.words }
            .prefix(6).map { $0 }
    }

    struct AppRow {
        let id: String
        let name: String
        let icon: NSImage?
        let words: Int

        /// Installed app name and icon via LaunchServices; falls back to the last path component.
        static func resolve(bundleID: String, words: Int) -> AppRow {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let name = FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "")
                return AppRow(id: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), words: words)
            }
            let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            return AppRow(id: bundleID, name: last, icon: nil, words: words)
        }
    }

    // MARK: cards

    private var topTiles: some View {
        let d = DictionaryStore.load()
        return HStack(spacing: Brand.s12) {
            StatTile(value: "\(wpm)", label: "words per minute",
                     hint: wpm > 0 ? "your speaking pace" : "dictate once to measure")
            StatTile(value: "\(Stats.fixesAccepted)", label: "fixes you taught it",
                     hint: "\(d.vocab.count) terms, \(d.replacements.count) replacements")
            StatTile(value: format(words), label: "words dictated",
                     hint: savedHours >= 0.1 ? String(format: "about %.1f hours saved vs typing at 40 wpm", savedHours) : "keep going")
        }
        .frame(height: 118)
    }

    private var perDayCard: some View {
        let series = Stats.dailySeries(days: 14, map: daily)
        let peak = max(series.map(\.words).max() ?? 0, 1)
        return card {
            label("words per day · last 14 days")
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(series, id: \.date) { d in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(d.words > 0 ? Brand.coral.opacity(0.25 + 0.75 * Double(d.words) / Double(peak)) : Brand.line)
                            .frame(height: max(3, 64 * CGFloat(d.words) / CGFloat(peak)))
                        Text(dayLetter(d.date)).font(Brand.mono(9)).foregroundStyle(Brand.muted)
                    }
                }
            }
            .frame(height: 84, alignment: .bottom)
        }
    }

    private var meetingsCard: some View {
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())
        let mine = meetings.compactMap { m in m.speakers.first { $0.name == m.you } }
        let share = mine.isEmpty ? 0 : mine.map(\.sharePct).reduce(0, +) / Double(mine.count)
        return card {
            HStack(alignment: .firstTextBaseline, spacing: Brand.s8) {
                Text("\(overview.meetingsCount)").font(Brand.serif(26)).monospacedDigit().foregroundStyle(Brand.text)
                label("meetings")
            }
            if overview.meetingsWithStats < overview.meetingsCount {
                Text("stats for \(overview.meetingsWithStats) of \(overview.meetingsCount)")
                    .font(Brand.caption).foregroundStyle(Brand.muted)
            }
            if meetings.isEmpty {
                Text("No meeting stats yet. They appear after your next recorded meeting.")
                    .font(Brand.body).foregroundStyle(Brand.muted).padding(.top, Brand.s4)
            } else {
                HStack(spacing: Brand.s12) {
                    StatTile(value: "\(meetings.filter { week?.contains($0.date) ?? false }.count)", label: "this week")
                    StatTile(value: String(format: "%.1f", meetings.map(\.duration).reduce(0, +) / 3600), label: "meeting hours")
                    StatTile(value: "\(Int(share.rounded()))%", label: "your avg talk share")
                    StatTile(value: MeetingController.mmss(mine.map(\.longestMonologue).max() ?? 0), label: "longest monologue")
                }
                .frame(height: 78)
                .padding(.top, Brand.s8)
            }
        }
    }

    private var appsCard: some View {
        let total = max(apps.reduce(0) { $0 + $1.words }, 1)
        return card {
            label("where you dictate")
            if apps.isEmpty {
                Text("No app data yet. It fills in as you dictate.")
                    .font(Brand.body).foregroundStyle(Brand.muted).padding(.top, Brand.s4)
            } else {
                ForEach(apps, id: \.id) { a in
                    let pct = Int((Double(a.words) / Double(total) * 100).rounded())
                    HStack(spacing: Brand.s8) {
                        if let icon = a.icon {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "app").frame(width: 16, height: 16).foregroundStyle(Brand.muted)
                        }
                        Text(a.name).font(Brand.body).foregroundStyle(Brand.text)
                            .frame(width: 96, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 4).fill(Brand.coral.opacity(0.85))
                                .frame(width: max(3, g.size.width * CGFloat(a.words) / CGFloat(total)), height: 16)
                        }
                        .frame(height: 16)
                        Text("\(pct)%").font(Brand.mono(11)).foregroundStyle(Brand.muted)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var heatmapCard: some View {
        let cal = Calendar.current
        let weeks = 10
        let peak = max(daily.values.max() ?? 0, 1)
        // column = week (oldest → newest), row = weekday; anchor on the most recent Saturday
        let today = cal.startOfDay(for: Date())
        let endOffset = 6 - (cal.component(.weekday, from: today) - 1)
        let end = cal.date(byAdding: .day, value: endOffset, to: today) ?? today
        return card {
            HStack {
                label("\(overview.streakDays) day streak")
                Spacer()
                Text("longest streak \(Stats.longestStreak(map: daily)) days, all time")
                    .font(Brand.mono(10)).foregroundStyle(Brand.muted)
            }
            HStack(spacing: 3) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { r in
                            let back = (weeks - 1 - w) * 7 + (6 - r)
                            let day = cal.date(byAdding: .day, value: -back, to: end) ?? end
                            let n = daily[Stats.dayKey(day)] ?? 0
                            let bucket = Stats.heatBucket(words: n, max: peak)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(bucket == 0 ? Brand.line.opacity(0.45) : Brand.coral.opacity(0.2 + 0.2 * Double(bucket)))
                                .frame(width: 11, height: 11)
                                .overlay(RoundedRectangle(cornerRadius: 2)
                                    .stroke(cal.isDate(day, inSameDayAs: today) ? Brand.coral : .clear, lineWidth: 1.2))
                        }
                    }
                }
            }
            .padding(.top, 6)
            Text("Last 10 weeks. Darker means more words that day.").font(Brand.caption).foregroundStyle(Brand.muted).padding(.top, Brand.s4)
        }
    }

    // MARK: bits

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { content() }
            .padding(Brand.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Brand.rMd).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: Brand.rMd).stroke(Brand.line))
    }

    private func label(_ t: String) -> some View {
        Text(t).font(Brand.heading).foregroundStyle(Brand.text)
    }

    private func format(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    private func dayLetter(_ d: Date) -> String {
        ["S", "M", "T", "W", "T", "F", "S"][Calendar.current.component(.weekday, from: d) - 1]
    }
}
