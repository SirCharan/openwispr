import Foundation

struct MeetingLine: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var speaker: String // "You" (mic) or "Others" (system audio)
    var text: String
}

/// Records a meeting from two streams — mic ("You") and system audio ("Others") —
/// rotating chunks on a timer and transcribing each in the background for a live transcript.
/// ponytail: fixed 20s chunk rotation, no VAD model — good boundaries for meeting notes;
/// upgrade to Silero VAD (FluidAudio) if mid-word cuts prove annoying.
@MainActor
final class MeetingController: ObservableObject {
    @Published private(set) var lines: [MeetingLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = "idle"

    private let mic = AudioRecorder()
    private let system = SystemAudioRecorder()
    private let transcriber: Transcriber
    private var timer: Timer?
    private let chunkSeconds: TimeInterval = 20
    private let minSamples = 8000 // ignore chunks under 0.5 s

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    func start() async {
        guard !isRunning else { return }
        do {
            try mic.start()
            try await system.start()
        } catch {
            status = "start failed: \(error.localizedDescription)"
            _ = mic.stop()
            return
        }
        isRunning = true
        status = "recording"
        timer = Timer.scheduledTimer(withTimeInterval: chunkSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rotateChunks() }
        }
    }

    func stop() async {
        guard isRunning else { return }
        timer?.invalidate(); timer = nil
        let micTail = mic.stop()
        let sysTail = await system.stop()
        isRunning = false
        status = "finishing…"
        await transcribeChunk(micTail, speaker: "You")
        await transcribeChunk(sysTail, speaker: "Others")
        status = "done"
    }

    private func rotateChunks() {
        guard isRunning else { return }
        let micChunk = mic.drain()
        let sysChunk = system.drain()
        Task {
            await transcribeChunk(micChunk, speaker: "You")
            await transcribeChunk(sysChunk, speaker: "Others")
        }
    }

    private func transcribeChunk(_ samples: [Float], speaker: String) async {
        guard samples.count >= minSamples else { return }
        // skip silent chunks (RMS gate)
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard rms > 0.002 else { return }
        do {
            let raw = try await transcriber.transcribe(samples, language: Settings.languageCode)
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
        for line in lines {
            let t = DateFormatter.localizedString(from: line.date, dateStyle: .none, timeStyle: .short)
            md += "**\(line.speaker)** (\(t)): \(line.text)\n\n"
        }
        return md
    }
}
