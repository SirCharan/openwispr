import Foundation

struct MeetingLine: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var speaker: String // "You" (mic) or "Others" (system audio)
    var text: String
}

/// Records a meeting from two streams — mic ("You") and system audio ("Others") —
/// rotating each stream's chunk at natural speech pauses and transcribing in the background.
/// ponytail: energy-based pause detection (tail RMS), not a VAD model — Silero VAD via
/// FluidAudio is the upgrade path if mid-word cuts prove annoying.
@MainActor
final class MeetingController: ObservableObject {
    @Published private(set) var lines: [MeetingLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = "idle"
    @Published var summary: String?
    @Published private(set) var summarizing = false
    @Published private(set) var needsScreenRec = false
    @Published private(set) var savedTo: String?

    private let mic = AudioRecorder()
    private let system = SystemAudioRecorder()
    private let transcriber: Transcriber
    private var timer: Timer?
    private let minSamples = 8000        // ignore chunks under 0.5 s
    private let minChunkSeconds = 6.0    // don't rotate more often than this
    private let maxChunkSeconds = 30.0   // force rotation at this length
    private let pauseWindow = 0.7        // trailing seconds that must be quiet
    private let pauseRMS: Float = 0.004  // "quiet" threshold

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    private var starting = false

    func start() async {
        guard !isRunning, !starting else { return }
        starting = true // synchronous, before any await — a second tap during startup must bounce
        defer { starting = false }
        do {
            try mic.start()
            try await system.start()
        } catch {
            // SCStream TCC denial → point at the fix instead of a raw error
            needsScreenRec = (error as NSError).domain.contains("ScreenCaptureKit")
            status = needsScreenRec ? "needs Screen Recording permission" : "start failed: \(error.localizedDescription)"
            _ = mic.stop()
            return
        }
        isRunning = true
        needsScreenRec = false
        status = "recording"
        summary = nil
        savedTo = nil
        lines.removeAll() // fresh meeting — don't interleave with the previous one
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkRotation() }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false // clear before awaits so a double-stop can't re-enter teardown
        timer?.invalidate(); timer = nil
        let micTail = mic.stop()
        let sysTail = await system.stop()
        status = "finishing…"
        await transcribeChunk(micTail, speaker: "You")
        await transcribeChunk(sysTail, speaker: "Others")
        status = "done"
        if !lines.isEmpty {
            Stats.recordMeeting()
            autosave()
        }
    }

    /// Quit/crash safety: every finished meeting lands in ~/Documents/Whispr automatically.
    private func autosave() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("meeting-\(stamp).md")
        do {
            try exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
            savedTo = url.path
            status = "done — saved to Documents/OpenWispr"
        } catch {
            NSLog("[Whispr] meeting autosave failed: \(error)")
        }
    }

    /// Rotate a stream when its speaker pauses (quiet tail) after enough audio,
    /// or unconditionally at maxChunkSeconds.
    private func checkRotation() {
        guard isRunning else { return }
        rotateIfDue(buffered: mic.bufferedSeconds, tail: mic.tailRMS(pauseWindow)) {
            let chunk = self.mic.drain()
            Task { await self.transcribeChunk(chunk, speaker: "You") }
        }
        rotateIfDue(buffered: system.bufferedSeconds, tail: system.tailRMS(pauseWindow)) {
            let chunk = self.system.drain()
            Task { await self.transcribeChunk(chunk, speaker: "Others") }
        }
    }

    private func rotateIfDue(buffered: Double, tail: Float, rotate: () -> Void) {
        guard buffered >= minChunkSeconds else { return }
        if tail < pauseRMS || buffered >= maxChunkSeconds { rotate() }
    }

    // MARK: - AI summary (BYOK, optional)

    func summarize() async {
        guard !lines.isEmpty, !summarizing else { return }
        summarizing = true
        defer { summarizing = false }
        let transcript = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        do {
            summary = try await LLMClient.complete(
                system: """
                You summarize meeting transcripts. "You" is the local user; "Others" are remote participants.
                Reply in Markdown with exactly these sections: ## Summary (2-4 sentences),
                ## Decisions (bullets, or "None"), ## Action items (bullets with owner if known, or "None").
                """,
                user: transcript
            )
        } catch {
            summary = "_\(error.localizedDescription)_"
        }
    }

    private func transcribeChunk(_ samples: [Float], speaker: String) async {
        guard samples.count >= minSamples else { return }
        // skip silent chunks (RMS gate)
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard rms > 0.002 else { return }
        do {
            var raw = try await transcriber.transcribe(samples, language: Settings.languageCode)
            if Settings.outputMode == "roman" { raw = Transliterate.toLatin(raw) }
            let text = TextProcessor.process(raw, options: Settings.textOptions)
            guard !text.isEmpty else { return }
            lines.append(MeetingLine(speaker: speaker, text: text))
        } catch {
            NSLog("[Whispr] meeting chunk failed (\(speaker)): \(error)")
        }
    }

    // MARK: - Export

    func exportMarkdown() -> String {
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short
        var md = "# Meeting transcript — \(df.string(from: lines.first?.date ?? Date()))\n\n"
        if let summary, !summary.isEmpty {
            md += summary + "\n\n---\n\n"
        }
        for line in lines {
            let t = DateFormatter.localizedString(from: line.date, dateStyle: .none, timeStyle: .short)
            md += "**\(line.speaker)** (\(t)): \(line.text)\n\n"
        }
        return md
    }
}
