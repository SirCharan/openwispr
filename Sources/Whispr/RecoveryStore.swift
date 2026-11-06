import Foundation

/// A dictation whose transcription failed (or came back empty after speech). The audio stays on
/// disk until retried or discarded. Adapted from Muesli (MIT) DictationRecoveryStore.swift.
struct FailedDictation: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let seconds: Double
    let appBundleID: String?
    let message: String
    var partialText: String?
}

/// `~/Library/Application Support/OpenWispr/Recovery/<id>/{audio.wav,failure.json}`.
/// Successful dictations never touch it. Capped at 20 entries / 7 days.
struct RecoveryStore {
    static let maxEntries = 20
    static let maxAge: TimeInterval = 7 * 24 * 3600

    let directory: URL

    static let standard = RecoveryStore(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWispr/Recovery", isDirectory: true))

    /// Snapshot renders only (`--snap-panes`).
    nonisolated(unsafe) static var sampleOverride: [FailedDictation]?

    private func session(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }

    @discardableResult
    func save(samples: [Float], appBundleID: String?, message: String, partialText: String? = nil,
              startedAt: Date = Date()) -> FailedDictation? {
        guard !samples.isEmpty else { return nil }
        let rec = FailedDictation(id: UUID(), startedAt: startedAt, seconds: Double(samples.count) / 16000,
                                  appBundleID: appBundleID, message: message, partialText: partialText)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: session(rec.id), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try WavEncoder.encode(samples).write(to: session(rec.id).appendingPathComponent("audio.wav"), options: .atomic)
            try JSONEncoder().encode(rec).write(to: session(rec.id).appendingPathComponent("failure.json"), options: .atomic)
        } catch {
            try? fm.removeItem(at: session(rec.id))
            Log.app.error("recovery save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        prune()
        return rec
    }

    /// Newest first.
    func list() -> [FailedDictation] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            (try? Data(contentsOf: d.appendingPathComponent("failure.json")))
                .flatMap { try? JSONDecoder().decode(FailedDictation.self, from: $0) }
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func samples(for rec: FailedDictation) -> [Float]? {
        try? WavEncoder.decode16kMono(path: session(rec.id).appendingPathComponent("audio.wav").path)
    }

    func discard(_ rec: FailedDictation) { try? FileManager.default.removeItem(at: session(rec.id)) }

    /// Drop entries older than 7 days, then the oldest beyond 20.
    func prune(now: Date = Date()) {
        var keep = list()
        for r in keep where now.timeIntervalSince(r.startedAt) > Self.maxAge { discard(r) }
        keep.removeAll { now.timeIntervalSince($0.startedAt) > Self.maxAge }
        for r in keep.dropFirst(Self.maxEntries) { discard(r) }
    }

    static func selfTest() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecoveryStore(directory: dir)
        let tone = (0..<16000).map { Float(sin(Double($0) / 20)) * 0.3 }
        Fixtures.expect(store.save(samples: [], appBundleID: nil, message: "x") == nil, "empty audio is not saved")
        let a = store.save(samples: tone, appBundleID: "com.apple.Notes", message: "boom", partialText: "hello")
        Fixtures.expect(a != nil, "save returns a record")
        let got = store.list()
        Fixtures.expectEqual(got.count, 1, "round-trip count")
        Fixtures.expectEqual(got.first?.partialText ?? "", "hello", "round-trip partial text")
        Fixtures.expectEqual(got.first?.appBundleID ?? "", "com.apple.Notes", "round-trip bundle id")
        Fixtures.expect((store.samples(for: got[0])?.count ?? 0) == 16000, "round-trip audio length")
        // pruning: 22 fresh entries → 20 kept; one 8-day-old entry → dropped
        for _ in 0..<21 { store.save(samples: tone, appBundleID: nil, message: "m") }
        Fixtures.expectEqual(store.list().count, RecoveryStore.maxEntries, "capped at 20")
        store.prune(now: Date().addingTimeInterval(8 * 24 * 3600))
        Fixtures.expectEqual(store.list().count, 0, "7-day expiry")
        print("RecoveryStore.selfTest PASS")
    }
}
