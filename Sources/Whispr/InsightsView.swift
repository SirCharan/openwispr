import SwiftUI

/// Insights: WPM gauge, fixes, lifetime words + time saved, per-app usage, streak heatmap, words/day.
/// Everything here is derived from real local data (Stats aggregates) — no invented ranks or percentiles.
struct InsightsPane: View {
    @State private var entries: [HistoryEntry] = []
    @State private var daily: [String: Int] = [:]
    @State private var apps: [(name: String, words: Int)] = []

    private var wpm: Int { Stats.avgWPM(entries: entries) }
    private var words: Int { max(Stats.lifetimeWords, entries.reduce(0) { $0 + $1.words }) }
    private var savedHours: Double { Stats.timeSavedMinutes(words: words, wpm: wpm) / 60 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    gaugeCard
                    fixesCard
                    wordsCard
                }
                perDayCard
                HStack(alignment: .top, spacing: 14) {
                    appsCard
                    heatmapCard
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Brand.bg)
        .onAppear(perform: load)
    }

    private func load() {
        entries = HistoryStore.load()
        daily = Stats.dailyWords
        apps = Stats.appWords
            .map { (AppMonitor.name(for: $0.key), $0.value) }
            .sorted { $0.1 > $1.1 }
            .prefix(6).map { $0 }
    }

    // MARK: cards

    private var gaugeCard: some View {
        card {
            Text("\(wpm)").font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(Brand.text)
            label("words per minute")
            Gauge(value: Double(wpm), max: 200)
                .frame(height: 74).padding(.top, 6)
            Text(wpm > 0 ? "your speaking pace" : "dictate once to measure")
                .font(.system(size: 11)).foregroundStyle(Brand.muted)
        }
    }

    private var fixesCard: some View {
        let d = DictionaryStore.load()
        return card {
            Text("\(Stats.fixesAccepted)").font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(Brand.text)
            label("fixes you taught it")
            Divider().overlay(Brand.line).padding(.vertical, 4)
            row("\(d.vocab.count)", "dictionary terms")
            row("\(d.replacements.count)", "replacements")
        }
    }

    private var wordsCard: some View {
        card {
            Text(format(words)).font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(Brand.text)
            label("total words dictated")
            Divider().overlay(Brand.line).padding(.vertical, 4)
            Text(savedHours >= 0.1 ? String(format: "~%.1f hours saved", savedHours) : "keep going")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.coral)
            Text("vs typing the same words at 40 wpm")
                .font(.system(size: 11)).foregroundStyle(Brand.muted)
        }
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
                        Text(dayLetter(d.date)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Brand.muted)
                    }
                }
            }
            .frame(height: 84, alignment: .bottom)
        }
    }

    private var appsCard: some View {
        let total = max(apps.reduce(0) { $0 + $1.words }, 1)
        return card {
            label("where you dictate")
            if apps.isEmpty {
                Text("No app data yet — this starts counting from v0.14.")
                    .font(.system(size: 12)).foregroundStyle(Brand.muted).padding(.top, 4)
            } else {
                ForEach(apps, id: \.name) { a in
                    let pct = Int((Double(a.words) / Double(total) * 100).rounded())
                    HStack(spacing: 10) {
                        Text(a.name).font(.system(size: 12)).foregroundStyle(Brand.text)
                            .frame(width: 96, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 4).fill(Brand.coral.opacity(0.85))
                                .frame(width: max(3, g.size.width * CGFloat(a.words) / CGFloat(total)), height: 16)
                        }
                        .frame(height: 16)
                        Text("\(pct)%").font(.system(size: 11, design: .monospaced)).foregroundStyle(Brand.muted)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var heatmapCard: some View {
        let cal = Calendar.current
        let weeks = 18
        let peak = max(daily.values.max() ?? 0, 1)
        // column = week (oldest → newest), row = weekday; anchor on the most recent Saturday
        let today = cal.startOfDay(for: Date())
        let endOffset = 6 - (cal.component(.weekday, from: today) - 1)
        let end = cal.date(byAdding: .day, value: endOffset, to: today) ?? today
        return card {
            HStack {
                label("\(Stats.streak(entries: entries)) day streak")
                Spacer()
                Text("longest \(Stats.longestStreak(map: daily))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.muted)
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
            Text("darker = more words that day").font(.system(size: 10)).foregroundStyle(Brand.muted).padding(.top, 4)
        }
    }

    // MARK: bits

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line))
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(1.2).foregroundStyle(Brand.muted)
    }

    private func row(_ v: String, _ t: String) -> some View {
        HStack(spacing: 6) {
            Text(v).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Brand.text)
            Text(t).font(.system(size: 12)).foregroundStyle(Brand.muted)
        }
    }

    private func format(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    private func dayLetter(_ d: Date) -> String {
        ["S", "M", "T", "W", "T", "F", "S"][Calendar.current.component(.weekday, from: d) - 1]
    }
}

/// Semicircular pace dial (no percentile — we have no population data to rank against).
private struct Gauge: View {
    let value: Double
    let max: Double

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, r = Swift.min(w / 2, g.size.height) - 8
            let c = CGPoint(x: w / 2, y: r + 8)
            let frac = Swift.max(0, Swift.min(1, value / max))
            ZStack {
                arc(center: c, radius: r, to: 1).stroke(Brand.line, style: .init(lineWidth: 12, lineCap: .round))
                arc(center: c, radius: r, to: frac).stroke(Brand.coral, style: .init(lineWidth: 12, lineCap: .round))
            }
        }
    }

    private func arc(center: CGPoint, radius: CGFloat, to frac: Double) -> Path {
        Path { p in
            p.addArc(center: center, radius: radius,
                     startAngle: .degrees(180),
                     endAngle: .degrees(180 + 180 * frac),
                     clockwise: false)
        }
    }
}
