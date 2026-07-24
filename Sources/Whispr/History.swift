import Foundation

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var text: String
    var seconds: Double? // recording duration; absent in pre-v0.5 entries

    var words: Int { text.split(separator: " ").count }
}

/// Persists recent transcripts to Application Support/Whispr/history.json.
enum HistoryStore {
    static let cap = 200 // ponytail: keep last 200; add pagination only if it ever matters

    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }()

    static func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url),
              let h = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
        return h
    }

    static func add(_ text: String, seconds: Double? = nil) {
        var h = load()
        h.insert(HistoryEntry(text: text, seconds: seconds), at: 0)
        if h.count > cap { h = Array(h.prefix(cap)) }
        save(h)
    }

    static func save(_ h: [HistoryEntry]) {
        if let data = try? JSONEncoder().encode(h) { try? data.write(to: url, options: .atomic) }
    }

    static func clear() { save([]) }
}
