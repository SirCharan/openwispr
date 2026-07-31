import Foundation

struct MeetingLine: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var speaker: String   // "You" (mic), "Others"/"Speaker A/B…" (system), or a user label
    var text: String
    var start: Double = 0 // stream-timeline seconds (system stream for remote lines)
    var end: Double = 0
}

/// Records a meeting from two streams — mic ("You") and system audio (remote) — rotating
/// chunks at natural speech pauses. At Stop, the FULL system recording is diarized
/// (FluidAudio/pyannote, on-device) so remote lines become Speaker A/B/…, then the user
/// can rename speakers. Transcript checkpoints to disk after every line.
@MainActor
final class MeetingController: ObservableObject {
    @Published private(set) var lines: [MeetingLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var status = "idle"
    @Published var summary: String?
    @Published private(set) var summarizing = false
    @Published private(set) var needsScreenRec = false
    @Published private(set) var savedTo: String?
    @Published var showRenameSheet = false
    /// Per-meeting language override ("auto" = follow the global setting). Read per chunk, editable live.
    @Published var meetingLanguage = "auto"

    private let mic = AudioRecorder()
    private let system = SystemAudioRecorder()
    private let transcriber: Transcriber
    private let diarizer = Diarizer()
    private var timer: Timer?
    private let minSamples = 8000        // ignore chunks under 0.5 s
    private let minChunkSeconds = 6.0
    private let maxChunkSeconds = 30.0
    private let pauseWindow = 0.7
    private let pauseRMS: Float = 0.004

    // stream timelines (cumulative across pause/resume) + full system audio for stop-time diarization
    private var micOffset = 0.0
    private var sysOffset = 0.0
    private var fullSysAudio: [Float] = []
    // ponytail: full floats in RAM ≈ 230MB/hour — fine for normal meetings; stream-to-disk if ever needed
    private var meetingFile: URL?

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    private var starting = false

    func start() async {
        guard !isRunning, !starting else { return }
        starting = true // synchronous, before any await — a second tap during startup must bounce
        defer { starting = false }
        status = Settings.diarizationEnabled ? "preparing speaker model…" : "starting…"
        if Settings.diarizationEnabled {
            do { try await diarizer.prepare() } // idempotent; first run downloads ~100MB
            catch {
                NSLog("[Whispr] diarizer prepare failed, falling back to Others: \(error)")
                status = "speaker separation unavailable — using Others"
            }
        }
        do {
            try mic.start(voiceProcessing: true) // AEC: keep speaker playback out of "You"
            try await system.start()
        } catch {
            needsScreenRec = (error as NSError).domain.contains("ScreenCaptureKit")
            status = needsScreenRec ? "needs Screen Recording permission" : "start failed: \(error.localizedDescription)"
            _ = mic.stop()
            return
        }
        system.onUnexpectedStop = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isPaused else { return }
                self.status = "the other side's audio stopped (permission or display change) — press Stop, then start again to continue"
            }
        }
        isRunning = true
        isPaused = false
        needsScreenRec = false
        status = "recording"
        summary = nil
        savedTo = nil
        lines.removeAll()
        micOffset = 0; sysOffset = 0
        fullSysAudio.removeAll()
        // fix the checkpoint file at start so every save hits the same path
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        meetingFile = dir.appendingPathComponent("meeting-\(stamp).md")
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkRotation() }
        }
    }

    /// Pause: transcribe what's buffered, stop both engines. Resume restarts them; timeline stays cumulative.
    func pause() async {
        guard isRunning, !isPaused else { return }
        isPaused = true
        timer?.invalidate(); timer = nil
        status = "pausing…"
        let micTail = mic.stop()
        let sysTail = await system.stop()
        await ingest(micTail, speaker: "You", stream: .mic)
        await ingest(sysTail, speaker: "Others", stream: .system)
        status = "paused"
    }

    func resume() async {
        guard isRunning, isPaused else { return }
        do {
            try mic.start(voiceProcessing: true)
            try await system.start()
        } catch {
            status = "resume failed: \(error.localizedDescription)"
            return
        }
        isPaused = false
        status = "recording"
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkRotation() }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false // clear before awaits so a double-stop can't re-enter teardown
        timer?.invalidate(); timer = nil
        status = "finishing…"
        if !isPaused {
            let micTail = mic.stop()
            let sysTail = await system.stop()
            await ingest(micTail, speaker: "You", stream: .mic)
            await ingest(sysTail, speaker: "Others", stream: .system)
        }
        isPaused = false
        await applyDiarization()
        status = "done"
        if !lines.isEmpty {
            Stats.recordMeeting()
            autosave()
            showRenameSheet = true // ck's flow: label speakers right after the transcript is done
        }
    }

    /// Split "Others" lines into Speaker A/B/… using the full system recording. Falls back silently.
    private func applyDiarization() async {
        guard Settings.diarizationEnabled, !fullSysAudio.isEmpty else { return }
        status = "separating speakers…"
        let audio = fullSysAudio
        do {
            let segments = try await diarizer.diarize(audio)
            guard !segments.isEmpty else { return }
            for i in lines.indices where lines[i].speaker == "Others" {
                if let who = Diarizer.assign(start: lines[i].start, end: lines[i].end, segments: segments) {
                    lines[i].speaker = who
                }
            }
        } catch {
            NSLog("[Whispr] diarization failed, keeping Others: \(error)")
        }
    }

    /// Rename speakers (post-meeting labeling). Map old label -> new name; rewrites transcript + file.
    func renameSpeakers(_ mapping: [String: String]) {
        for i in lines.indices {
            if let new = mapping[lines[i].speaker], !new.trimmingCharacters(in: .whitespaces).isEmpty {
                lines[i].speaker = new.trimmingCharacters(in: .whitespaces)
            }
        }
        autosave()
    }

    var distinctSpeakers: [String] {
        var seen: [String] = []
        for l in lines where !seen.contains(l.speaker) { seen.append(l.speaker) }
        return seen
    }

    /// Checkpoint after every line: crash/quit loses at most one chunk.
    private func autosave() {
        guard let url = meetingFile else { return }
        do {
            try exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
            savedTo = url.path
        } catch {
            NSLog("[Whispr] meeting autosave failed: \(error)")
        }
    }

    private func checkRotation() {
        guard isRunning, !isPaused else { return }
        rotateIfDue(buffered: mic.bufferedSeconds, tail: mic.tailRMS(pauseWindow)) {
            let chunk = self.mic.drain()
            Task { await self.ingest(chunk, speaker: "You", stream: .mic) }
        }
        rotateIfDue(buffered: system.bufferedSeconds, tail: system.tailRMS(pauseWindow)) {
            let chunk = self.system.drain()
            Task { await self.ingest(chunk, speaker: "Others", stream: .system) }
        }
    }

    /// True when two lines from opposite streams overlap ≥50% of the shorter one and read the same
    /// (JW > 0.82) — i.e. the mic heard the speaker. Pure; self-tested.
    nonisolated static func isEchoPair(_ a: MeetingLine, _ b: MeetingLine) -> Bool {
        let overlap = min(a.end, b.end) - max(a.start, b.start)
        let shorter = min(a.end - a.start, b.end - b.start)
        guard shorter > 0, overlap >= shorter * 0.5 else { return false }
        return DictionaryStore.jaroWinkler(a.text.lowercased(), b.text.lowercased()) > 0.82
    }

    nonisolated static func selfTest() {
        func line(_ s: String, _ t0: Double, _ t1: Double) -> MeetingLine {
            MeetingLine(speaker: "x", text: s, start: t0, end: t1)
        }
        precondition(isEchoPair(line("we should add a card for delta global", 7, 12),
                          line("We should add a card for the delta global here", 7, 13)), "echo not caught")
        precondition(!isEchoPair(line("we should add a card", 7, 12),
                           line("now we can go to the call", 7, 12)), "different text flagged")
        precondition(!isEchoPair(line("we should add a card", 0, 5),
                           line("we should add a card", 40, 45)), "non-overlapping flagged")
        print("MeetingController.selfTest PASS")
    }

    private func rotateIfDue(buffered: Double, tail: Float, rotate: () -> Void) {
        guard buffered >= minChunkSeconds else { return }
        if tail < pauseRMS || buffered >= maxChunkSeconds { rotate() }
    }

    // MARK: - Chunk ingestion (timeline-stamped)

    private enum Stream { case mic, system }

    private func ingest(_ samples: [Float], speaker: String, stream: Stream) async {
        let duration = Double(samples.count) / 16000
        let start: Double
        switch stream {
        case .mic:
            start = micOffset; micOffset += duration
        case .system:
            start = sysOffset; sysOffset += duration
            fullSysAudio.append(contentsOf: samples) // kept for stop-time diarization
        }
        guard samples.count >= minSamples else { return }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard rms > 0.002 else { return }
        do {
            let language = meetingLanguage == "auto" ? Settings.languageCode : meetingLanguage
            var raw = try await transcriber.transcribe(samples, language: language)
            if Settings.outputMode == "roman" { raw = Transliterate.toLatin(raw) }
            raw = TextProcessor.collapseRepeats(raw) // hallucination loops on short call chunks
            let text = TextProcessor.process(raw, options: Settings.textOptions)
            guard !text.isEmpty else { return }
            let line = MeetingLine(speaker: speaker, text: text, start: start, end: start + duration)
            // echo dedup: same words on both streams = speaker bleed; keep the digital (system) copy
            if stream == .mic, lines.contains(where: { $0.speaker != "You" && Self.isEchoPair($0, line) }) { return }
            if stream == .system { lines.removeAll { $0.speaker == "You" && Self.isEchoPair($0, line) } }
            lines.append(line)
            lines.sort { $0.start < $1.start } // interleave You/Others in spoken order
            autosave() // live checkpoint
        } catch {
            NSLog("[Whispr] meeting chunk failed (\(speaker)): \(error)")
        }
    }

    // MARK: - AI summary (BYOK, optional)

    func summarize() async {
        guard !lines.isEmpty, !summarizing else { return }
        summarizing = true
        defer { summarizing = false }
        guard await LLMClient.available() else {
            summary = "_No AI provider configured. Install Ollama from ollama.com (then `ollama pull llama3.2`), or add an API key in the AI settings — then click Summarize again._"
            return
        }
        let transcript = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        do {
            summary = try await LLMClient.complete(
                system: """
                You summarize meeting transcripts. "You" is the local user; other names/speakers are remote participants.
                Reply in Markdown with exactly these sections: ## Summary (2-4 sentences),
                ## Decisions (bullets, or "None"), ## Action items (bullets with owner if known, or "None").
                """,
                user: transcript
            )
            autosave()
        } catch {
            summary = "_\(error.localizedDescription)_"
        }
    }

    // MARK: - Export

    static func mmss(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func exportMarkdown() -> String {
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short
        let duration = lines.map(\.end).max() ?? 0
        var md = "# Meeting transcript — \(df.string(from: lines.first?.date ?? Date()))\n"
        md += "Duration: \(Self.mmss(duration)) · \(distinctSpeakers.joined(separator: " · "))\n\n"
        if let summary, !summary.isEmpty {
            md += summary + "\n\n---\n\n"
        }
        for line in lines {
            md += "[\(Self.mmss(line.start))] **\(line.speaker)**: \(line.text)\n\n"
        }
        return md
    }
}
