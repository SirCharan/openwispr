import Foundation

/// Past meetings on disk: `~/Documents/OpenWispr/meeting-<stamp>.md` plus an optional `.stats.json`.
enum MeetingArchive {
    struct Entry: Identifiable, Equatable {
        var id: String { stamp }
        let stamp: String        // "2026-11-03T08-13-04" (UTC, as written by MeetingController)
        let date: Date
        let duration: String     // "m:ss" from the header
        let speakers: [String]
        let hasStats: Bool
    }

    struct Parsed {
        var duration = ""
        var speakers: [String] = []
        var lines: [MeetingLine] = []
    }

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenWispr")
    }

    static func fileURL(stamp: String, in dir: URL = directory) -> URL {
        dir.appendingPathComponent("meeting-\(stamp).md")
    }

    /// Header only: the first few lines carry "Duration: m:ss · A · B", so list() never parses a transcript.
    private static func header(of url: URL) -> Parsed {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Parsed() }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 1024)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return parse(text.split(separator: "\n", omittingEmptySubsequences: true).prefix(5).joined(separator: "\n"))
    }

    static func date(fromStamp stamp: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.date(from: stamp)
    }

    /// Newest first.
    static func list(in dir: URL = directory) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let names = Set(files.map(\.lastPathComponent))
        return files.compactMap { url -> Entry? in
            let n = url.lastPathComponent
            guard n.hasPrefix("meeting-"), n.hasSuffix(".md") else { return nil }
            let stamp = String(n.dropFirst("meeting-".count).dropLast(".md".count))
            guard let d = date(fromStamp: stamp) else { return nil }
            let head = header(of: url)
            return Entry(stamp: stamp, date: d, duration: head.duration, speakers: head.speakers,
                         hasStats: names.contains("meeting-\(stamp).stats.json"))
        }.sorted { $0.date > $1.date }
    }

    static func load(stamp: String, in dir: URL = directory) -> (lines: [MeetingLine], stats: MeetingStats?)? {
        let md = fileURL(stamp: stamp, in: dir)
        guard let text = try? String(contentsOf: md, encoding: .utf8) else { return nil }
        var lines = parse(text).lines
        if let base = date(fromStamp: stamp) {
            for i in lines.indices { lines[i].date = base.addingTimeInterval(lines[i].start) }
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let stats = (try? Data(contentsOf: MeetingStatsStore.url(for: md))).flatMap { try? dec.decode(MeetingStats.self, from: $0) }
        return (lines, stats)
    }

    /// Header "Duration: m:ss · A · B", then "[m:ss] **Speaker**: text" lines.
    static func parse(_ md: String) -> Parsed {
        var out = Parsed()
        for raw in md.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("Duration:") {
                let parts = line.dropFirst("Duration:".count).components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
                out.duration = parts.first ?? ""
                out.speakers = Array(parts.dropFirst())
            } else if line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                      let secs = seconds(String(line[line.index(after: line.startIndex)..<close])) {
                let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard rest.hasPrefix("**"), let r = rest.range(of: "**: ") else { continue }
                let speaker = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<r.lowerBound])
                out.lines.append(MeetingLine(speaker: speaker, text: String(rest[r.upperBound...]), start: secs, end: secs))
            }
        }
        return out
    }

    private static func seconds(_ s: String) -> Double? {
        let p = s.split(separator: ":").compactMap { Double($0) }
        guard p.count >= 2, p.count == s.split(separator: ":").count else { return nil }
        return p.reduce(0) { $0 * 60 + $1 }
    }

    static func selfTest() {
        let md = "# Meeting transcript — 3 Nov 2026 at 1:43 PM\nDuration: 1:05 · You · Speaker A\n\n[0:28] **You**: hello: world\n\n[1:05] **Speaker A**: second\n\n"
        let p = parse(md)
        precondition(p.duration == "1:05" && p.speakers == ["You", "Speaker A"], "MeetingArchive header failed")
        precondition(p.lines.count == 2 && p.lines[0].start == 28 && p.lines[0].speaker == "You"
                     && p.lines[0].text == "hello: world" && p.lines[1].start == 65, "MeetingArchive lines failed")
        precondition(date(fromStamp: "2026-11-03T08-13-04") != nil, "MeetingArchive stamp failed")
        print("MeetingArchive.selfTest PASS (2 lines, duration \(p.duration), speakers \(p.speakers.count))")
    }
}
