import Foundation
import QuartzCore
import FluidAudio

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
    @Published private(set) var summaryChoice: SummaryChoice?   // nil until first probe
    @Published private(set) var summaryError: String?
    @Published private(set) var summarizingWith = ""
    @Published private(set) var needsScreenRec = false
    @Published private(set) var savedTo: String?
    @Published var showRenameSheet = false
    @Published private(set) var stats: MeetingStats?
    /// Per-stream capture health, shown in MeetingView so a dead stream never reads as a quiet room.
    @Published private(set) var micHealthy = true
    @Published private(set) var systemHealthy = true
    /// Persistent warning shown by MeetingView (unlike `status`, nothing overwrites it).
    @Published private(set) var banner: String?
    /// Per-meeting language override ("auto" = follow the global setting). Read per chunk, editable live.
    @Published var meetingLanguage = "auto"

    private let mic = AudioRecorder()
    private let system = SystemAudioRecorder()
    private let transcriber: Transcriber
    private let diarizer = Diarizer()
    private var timer: Timer?
    private let minSamples = 3200        // ignore chunks under 0.2 s
    /// Speech floor applied to the loudest half-second of a chunk (not its mean).
    /// Read from Settings so a quiet room can be tuned without a rebuild — see
    /// `Settings.meetingSpeechFloor` for the measurements behind the default.
    private var speechPeakRMS: Float { Float(Settings.meetingSpeechFloor) }
    /// Chunks dropped below the speech floor this meeting; reported once at stop.
    private var floorDrops = 0

    /// Meeting cleanup keeps capitalization and spacing but never deletes words.
    static let meetingTextOptions = TextProcessor.Options(removeFillers: false, cleanUp: true)

    // One shared clock (pause excluded). Each stream's raw sample count is kept equal to clock
    // time by zero-filling dropouts, so a sample index is a meeting timestamp on both streams.
    private var clock = MeetingClock()
    private var vadModel: VadManager?
    private var micSegV: MeetingSegmenter?
    private var sysSegV: MeetingSegmenter?
    private var micRaw = 0
    private var sysRaw = 0
    private var tick = 0
    private var pumpTask: Task<Void, Never>?
    /// Dropouts longer than this are zero-filled so the timeline shows them as silence.
    private let gapFillSeconds = 0.5
    // full system audio for stop-time diarization
    private var fullSysAudio: [Float] = []
    /// Set by AppController: is the detected meeting app Zoom right now?
    var isZoomMeeting: () -> Bool = { false }
    private var roster: ZoomRosterReader?
    /// Set by AppController: is a browser Meet window detected right now?
    var isMeetWindow: () -> Bool = { false }
    var meetServer: MeetRosterServer?
    /// Shown once per meeting when no extension event arrives within 20 s of Start on a Meet window.
    @Published private(set) var meetHint: String?
    private var meetTimeline: RosterTimeline?
    /// Set by AppController: id of the detected meeting window ("us.zoom.xos", "meet.google.com", …).
    var meetingAppID: () -> String? = { nil }
    private var screenNames: ScreenSpeakerReader?
    // ponytail: full floats in RAM ≈ 230MB/hour — fine for normal meetings; stream-to-disk if ever needed
    private var meetingFile: URL?
    private var diarSegments: [Diarizer.Segment] = []
    private var youLabel = "You"

    // raw-audio retention
    private var micWav: WavEncoder.Writer?
    private var sysWav: WavEncoder.Writer?

    // liveness tracking (buffer arrival, not energy)
    private let stallTicks = 5            // seconds of no buffers before a stream is called dead
    private let maxSysRestarts = 8
    private var lastMicAppends = 0
    private var lastSysAppends = 0
    private var micQuietTicks = 0
    private var sysQuietTicks = 0
    private var sysRestartAttempts = 0
    private var sysRestartCooldown = 0

    // mic-dead watchdog: buffers arrive but carry no signal (VPIO + another app on the input)
    private var micWatchdog = MicDeadWatchdog()
    private var micWatchdogTripped = false
    private var micDeadRestarts = 0
    private var micLost = false
    private var micVoiceProcessing = false
    private let maxMicDeadRestarts = 2

    // ordered transcription queue
    private var pending: [PendingChunk] = []
    private var drainTask: Task<Void, Never>?

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    private var starting = false

    func start() async {
        guard !isRunning, !starting else { return }
        guard LicenseManager.shared.gate(.meet) else { return }
        starting = true // synchronous, before any await — a second tap during startup must bounce
        defer { starting = false }
        status = Settings.diarizationEnabled ? "preparing speaker model…" : "starting…"
        if Settings.diarizationEnabled {
            do { try await diarizer.prepare() } // idempotent; first run downloads ~100MB
            catch {
                Log.audio.error("diarizer prepare failed, falling back to Others: \(error.localizedDescription, privacy: .public)")
                status = "speaker separation unavailable — using Others"
            }
        }
        // Assigned BEFORE start: a teardown during startup used to land in the gap between
        // system.start() and this line, and was lost.
        system.onUnexpectedStop = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isPaused else { return }
                self.systemHealthy = false
                self.status = "the other side's audio dropped — reconnecting…"
                await self.restartSystemAudio()
            }
        }
        if vadModel == nil { vadModel = await MeetingSegmenter.loadVad() }
        do {
            micVoiceProcessing = Settings.meetingMicVoiceProcessing
            // AEC is opt-in (meetingMicVoiceProcessing): it left the mic silent with Chrome on Meet
            try mic.start(voiceProcessing: micVoiceProcessing)
            try await system.start()
        } catch {
            needsScreenRec = (error as NSError).domain.contains("ScreenCaptureKit")
            status = needsScreenRec ? "needs Screen Recording permission" : "start failed: \(error.localizedDescription)"
            _ = mic.stop()
            return
        }
        _ = mic.drain() // mic began before system.start(): discard so mic sample 0 == clock 0
        isRunning = true
        isPaused = false
        needsScreenRec = false
        status = "recording"
        summary = nil
        savedTo = nil
        lines.removeAll()
        clock = MeetingClock()
        micSegV = MeetingSegmenter(vad: vadModel); sysSegV = MeetingSegmenter(vad: vadModel)
        micRaw = 0; sysRaw = 0
        stats = nil; diarSegments = []; youLabel = "You"
        fullSysAudio.removeAll()
        pending.removeAll()
        // fix the checkpoint file at start so every save hits the same path
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        meetingFile = dir.appendingPathComponent("meeting-\(stamp).md")
        openAudioWriters(dir: dir, stamp: stamp)
        micHealthy = true
        systemHealthy = true
        banner = nil
        lastMicAppends = 0; lastSysAppends = 0
        micQuietTicks = 0; sysQuietTicks = 0
        sysRestartAttempts = 0; sysRestartCooldown = 0
        micWatchdog = MicDeadWatchdog(); micWatchdogTripped = false
        micDeadRestarts = 0; micLost = false
        Log.app.info("meeting: start voiceProcessing=\(self.micVoiceProcessing, privacy: .public)")
        startTimer()
        roster?.stop(); roster = nil
        if isZoomMeeting() {
            let rr = ZoomRosterReader(isZoom: { [weak self] in self?.isZoomMeeting() ?? false },
                                      clock: { [weak self] in
                guard let self, self.isRunning, !self.isPaused else { return nil }
                return self.clock.time(forHost: CACurrentMediaTime())
            })
            rr.start()
            roster = rr
        }
        meetServer?.clock = { nil }
        meetTimeline = nil
        if let ms = meetServer, isMeetWindow() || ms.joinedRecently {
            ms.timeline.reset()
            ms.clock = { [weak self] in
                guard let self, self.isRunning, !self.isPaused else { return nil }
                return self.clock.time(forHost: CACurrentMediaTime())
            }
            meetTimeline = ms.timeline
        }
        screenNames?.stop(); screenNames = nil
        if Settings.screenSpeakerNames, let id = meetingAppID() {
            let sr = ScreenSpeakerReader(kind: .init(meetingID: id), clock: { [weak self] in
                guard let self, self.isRunning, !self.isPaused else { return nil }
                return self.clock.time(forHost: CACurrentMediaTime())
            })
            screenNames = sr
            Task { await sr.start(meetingID: id) }
        }
        meetHint = nil
        if let ms = meetServer, isMeetWindow() {
            let began = Date()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.isRunning, (ms.lastEventAt ?? .distantPast) < began else { return }
                self.meetHint = "Speaker names for Google Meet need the OpenWispr Chrome extension. Click Set up on the Google Meet names row in Meetings."
            }
        }
    }

    // MARK: - Raw audio retention

    /// Keep the raw 16 kHz mono audio so a bad transcript can be re-run offline with
    /// `--transcribe-file` instead of being lost. 115 MB/hour/stream.
    private func openAudioWriters(dir: URL, stamp: String) {
        guard Settings.meetingAudioRetentionDays > 0 else { return }
        let audioDir = dir.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        pruneOldAudio(in: audioDir)
        do {
            micWav = try WavEncoder.Writer(url: audioDir.appendingPathComponent("meeting-\(stamp)-you.wav"))
            sysWav = try WavEncoder.Writer(url: audioDir.appendingPathComponent("meeting-\(stamp)-others.wav"))
            Log.app.info("meeting audio retention on → \(audioDir.path, privacy: .public)")
        } catch {
            Log.app.error("could not open meeting audio writers: \(error.localizedDescription, privacy: .public)")
            micWav = nil; sysWav = nil
        }
    }

    private func pruneOldAudio(in dir: URL) {
        let days = Settings.meetingAudioRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files where f.pathExtension == "wav" {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: f)
                Log.app.info("pruned old meeting audio \(f.lastPathComponent, privacy: .public)")
            }
        }
    }

    private func closeAudioWriters() {
        micWav?.close(); sysWav?.close()
        micWav = nil; sysWav = nil
    }

    // MARK: - Stream liveness

    /// A stream that starts and then delivers nothing used to be indistinguishable from a
    /// silent room. Watch buffer ARRIVAL (not energy) and say so out loud.
    private func checkHealth() {
        guard isRunning, !isPaused else { return }

        let micAppends = mic.diagnostics.appends
        if micAppends == lastMicAppends {
            micQuietTicks += 1
            if micQuietTicks == stallTicks {
                micHealthy = false
                Log.audio.error("mic: no buffers for \(self.stallTicks)s — input device stalled")
                status = "your microphone stopped delivering audio"
            }
        } else {
            if !micHealthy { Log.audio.info("mic: buffers resumed") }
            micQuietTicks = 0; micHealthy = true
        }
        lastMicAppends = micAppends

        if micWatchdogTripped {
            micWatchdogTripped = false
            if micDeadRestarts < maxMicDeadRestarts {
                micDeadRestarts += 1
                Log.audio.error("meeting mic dead for 10 s, restarting without voice processing (attempt \(self.micDeadRestarts)/\(self.maxMicDeadRestarts))")
                Task { await self.restartMicWithoutVoiceProcessing() }
            } else if !micLost {
                micLost = true
                Log.audio.error("meeting mic dead again after \(self.maxMicDeadRestarts) restarts — giving up")
                banner = Self.micLostBanner
            }
        }

        if sysRestartCooldown > 0 { sysRestartCooldown -= 1 }
        let sysAppends = system.diagnostics.appends
        if sysAppends == lastSysAppends {
            sysQuietTicks += 1
            if sysQuietTicks == stallTicks {
                systemHealthy = false
                Log.audio.error("others: no buffers for \(self.stallTicks)s — stream stalled")
                Task { await self.restartSystemAudio() }
            }
        } else {
            if !systemHealthy {
                Log.audio.info("others: buffers resumed")
                status = "recording"
            }
            sysQuietTicks = 0; systemHealthy = true; sysRestartAttempts = 0
            banner = micLost ? Self.micLostBanner : nil
        }
        lastSysAppends = sysAppends
    }

    static let micLostBanner = "Mic audio lost"

    /// Restart the mic engine with AEC off. The clock is untouched: `feed` zero-fills the gap by
    /// host time, so the mic WAV stays aligned with the system stream.
    private func restartMicWithoutVoiceProcessing() async {
        await pumpTask?.value
        guard isRunning, !isPaused else { return }
        await feed(mic.stop(), stream: .mic)
        micVoiceProcessing = false
        for attempt in 1...2 {
            do {
                try mic.start(voiceProcessing: false)
                _ = mic.drain() // discard the first buffer, as start() does
                micWatchdog = MicDeadWatchdog()
                lastMicAppends = mic.diagnostics.appends; micQuietTicks = 0
                return
            } catch {
                Log.audio.error("meeting mic restart failed (try \(attempt)/2): \(describeOSStatus(error), privacy: .public)")
                if attempt == 1 {
                    _ = mic.stop()
                    try? await Task.sleep(for: .milliseconds(500))
                    guard isRunning, !isPaused else { return }
                }
            }
        }
        micHealthy = false
        status = "your microphone stopped delivering audio"
        banner = Self.micLostBanner
        micLost = true
    }

    /// Reconnect the system-audio tap with exponential backoff, keeping buffered audio.
    private func restartSystemAudio() async {
        guard isRunning, !isPaused, sysRestartCooldown == 0 else { return }
        guard sysRestartAttempts < maxSysRestarts else {
            status = "the other side's audio is unavailable — this transcript will be mic-only"
            banner = "System audio lost, recording mic only"
            return
        }
        sysRestartAttempts += 1
        let backoff = min(30, Int(pow(2.0, Double(sysRestartAttempts - 1))))
        sysRestartCooldown = backoff
        sysQuietTicks = 0
        Log.audio.info("others: restart attempt \(self.sysRestartAttempts)/\(self.maxSysRestarts), next retry in \(backoff)s")
        do {
            try await system.restart()
            status = "recording"
        } catch {
            Log.audio.error("others: restart failed: \(error.localizedDescription, privacy: .public)")
            status = "reconnecting the other side's audio…"
        }
    }

    /// Pause: transcribe what's buffered, stop both engines. Resume restarts them; timeline stays cumulative.
    private var transitioning = false

    func pause() async {
        guard isRunning, !isPaused else { return }
        guard !transitioning else { Log.audio.info("pause ignored: another transition in flight"); return }
        transitioning = true
        defer { transitioning = false }
        status = "pausing…"
        await finishStreams()
        clock.pause()
        isPaused = true
        await flushPending()
        status = "paused"
    }

    func resume() async {
        guard isRunning, isPaused else { return }
        guard !transitioning else { Log.audio.info("resume ignored: another transition in flight"); return }
        transitioning = true
        defer { transitioning = false }
        do {
            try mic.start(voiceProcessing: micVoiceProcessing)
            try await system.start()
        } catch {
            _ = mic.stop() // mic may already be running if the system stream was what failed
            status = "resume failed: \(error.localizedDescription)"
            return
        }
        _ = mic.drain()
        isPaused = false
        clock.resume()
        status = "recording"
        lastMicAppends = mic.diagnostics.appends
        lastSysAppends = system.diagnostics.appends
        micQuietTicks = 0; sysQuietTicks = 0
        micWatchdog = MicDeadWatchdog(); micWatchdogTripped = false
        startTimer()
    }

    func stop() async {
        guard isRunning else { return }
        guard !transitioning else { Log.audio.info("stop ignored: another transition in flight"); return }
        transitioning = true
        defer { transitioning = false }
        isRunning = false // clear before awaits so a double-stop can't re-enter teardown
        timer?.invalidate(); timer = nil
        status = "finishing…"
        if !isPaused { await finishStreams() }
        isPaused = false
        // Finish the backlog before closing up: this is where queued chunks used to vanish.
        if !pending.isEmpty { status = "transcribing the last \(pending.count) chunk(s)…" }
        await flushPending()
        closeAudioWriters()
        roster?.stop()
        screenNames?.stop()
        let segments = await applyDiarization()
        meetServer?.clock = { nil }
        if !segments.isEmpty {
            // Zoom and Meet never coexist: at most one of these is set.
            var map = (roster?.timeline.names(forDiarized: segments) ?? [:])
                .merging(meetTimeline?.names(forDiarized: segments) ?? [:]) { a, _ in a }
            // Screen OCR only fills speakers (and names) the extension / AX paths left open.
            for (sp, n) in screenNames?.timeline.names(forDiarized: segments) ?? [:]
            where map[sp] == nil && !map.values.contains(n) { map[sp] = n }
            if !map.isEmpty { renameSpeakers(map) }
        }
        roster = nil; meetTimeline = nil; screenNames = nil
        // The floor is calibrated on one room and one mic gain. A high drop count is the signal
        // to loosen `meetingSpeechFloor` — surfaced here so the user doesn't need Console.app.
        if floorDrops > 0 {
            Log.audio.info("meeting ended: \(self.floorDrops, privacy: .public) chunk(s) dropped below the speech floor \(self.speechPeakRMS, format: .fixed(precision: 4), privacy: .public) — if quiet speech is missing, lower meetingSpeechFloor")
        }
        floorDrops = 0
        Log.app.info("meeting: stop lines=\(self.lines.count, privacy: .public)")
        status = "done"
        if !lines.isEmpty {
            Stats.recordMeeting()
            autosave()
            refreshStats()
            showRenameSheet = true // ck's flow: label speakers right after the transcript is done
        }
    }

    /// Split "Others" lines into Speaker A/B/… using the full system recording. Falls back silently.
    @discardableResult
    private func applyDiarization() async -> [Diarizer.Segment] {
        guard Settings.diarizationEnabled, !fullSysAudio.isEmpty else { return [] }
        status = "separating speakers…"
        let audio = fullSysAudio
        do {
            let segments = try await diarizer.diarize(audio)
            guard !segments.isEmpty else { return [] }
            diarSegments = segments
            for i in lines.indices where lines[i].speaker == "Others" {
                if let who = Diarizer.assign(start: lines[i].start, end: lines[i].end, segments: segments) {
                    lines[i].speaker = who
                }
            }
            return segments
        } catch {
            Log.audio.error("diarization failed, keeping Others: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Rename speakers (post-meeting labeling). Map old label -> new name; rewrites transcript + file.
    func renameSpeakers(_ mapping: [String: String]) {
        for i in lines.indices {
            if let new = mapping[lines[i].speaker], !new.trimmingCharacters(in: .whitespaces).isEmpty {
                lines[i].speaker = new.trimmingCharacters(in: .whitespaces)
            }
        }
        diarSegments = diarSegments.map { Diarizer.Segment(speaker: mapping[$0.speaker]?.trimmingCharacters(in: .whitespaces).nonEmpty ?? $0.speaker, start: $0.start, end: $0.end) }
        if let me = mapping[youLabel]?.trimmingCharacters(in: .whitespaces), !me.isEmpty { youLabel = me }
        autosave()
        refreshStats()
    }

    /// Stats segments: diarized remote speakers plus the mic ("You") lines, which are not diarized.
    /// Without diarization every line stands in as a segment.
    private func refreshStats() {
        let mine = lines.filter { diarSegments.isEmpty || $0.speaker == youLabel }
            .map { Diarizer.Segment(speaker: $0.speaker, start: $0.start, end: $0.end) }
        let s = MeetingStats.compute(segments: diarSegments + mine, lines: lines, date: lines.first?.date ?? Date(), you: youLabel)
        stats = s
        if let url = meetingFile { MeetingStatsStore.save(s, transcript: url) }
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
            Log.app.error("meeting autosave failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Capture pump (VAD segmentation on the shared clock)

    private func startTimer() {
        tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        guard isRunning, !isPaused else { return }
        tick += 1
        if tick % 4 == 0 { checkHealth() }
        guard pumpTask == nil else { return }
        pumpTask = Task { @MainActor in
            await feed(mic.drain(), stream: .mic)
            await feed(system.drain(), stream: .system)
            pumpTask = nil
        }
    }

    /// Stop both streams and push everything left (tails plus the segmenters' open speech) to the queue.
    private func finishStreams() async {
        timer?.invalidate(); timer = nil
        await pumpTask?.value
        let micTail = mic.stop()
        let sysTail = await system.stop()
        await feed(micTail, stream: .mic)
        await feed(sysTail, stream: .system)
        for seg in micSegV?.flush() ?? [] { enqueue(seg, speaker: "You", stream: .mic) }
        for seg in sysSegV?.flush() ?? [] { enqueue(seg, speaker: "Others", stream: .system) }
    }

    /// One drained slice: zero-fill any dropout so index == clock time, write the raw audio,
    /// run VAD, queue finished speech segments.
    private func feed(_ samples: [Float], stream: Stream) async {
        guard !samples.isEmpty else { return }
        let raw = stream == .mic ? micRaw : sysRaw
        let now = clock.time(forHost: CACurrentMediaTime())
        var data = samples
        let gap = (now - Double(samples.count) / 16000) - Double(raw) / 16000
        if gap > gapFillSeconds {
            Log.audio.info("\(stream == .mic ? "mic" : "others", privacy: .public): \(gap, format: .fixed(precision: 1), privacy: .public)s dropout zero-filled")
            data = [Float](repeating: 0, count: Int(gap * 16000)) + samples
        }
        let start = Double(raw) / 16000
        switch stream {
        case .mic:
            if micWatchdog.observe(rms: ResamplingBuffer.rms(samples), seconds: Double(samples.count) / 16000) {
                micWatchdogTripped = true
            }
            micRaw += data.count; micWav?.append(data)
        case .system:
            sysRaw += data.count; sysWav?.append(data)
            fullSysAudio.append(contentsOf: data) // kept for stop-time diarization
        }
        guard let seg = stream == .mic ? micSegV : sysSegV else { return }
        for out in await seg.feed(data, start: start) {
            enqueue(out, speaker: stream == .mic ? "You" : "Others", stream: stream)
        }
    }

    // MARK: - Ordered transcription queue

    private struct PendingChunk {
        let samples: [Float]
        let start: Double
        let speaker: String
        let stream: Stream
    }

    /// Rotation used to spawn an unstructured `Task` per chunk onto one serializing
    /// Transcriber actor. Once a chunk took longer to transcribe than the rotation interval the
    /// backlog grew for the rest of the meeting, chunks completed out of order, and everything
    /// still in flight at Stop was dropped — a 38-minute meeting produced 12 lines. One FIFO
    /// consumer instead: ordered, and drained to completion before the transcript is finished.
    private func enqueue(_ seg: MeetingSegmenter.Segment, speaker: String, stream: Stream) {
        guard !seg.samples.isEmpty else { return }
        pending.append(PendingChunk(samples: seg.samples, start: seg.start, speaker: speaker, stream: stream))
        if pending.count > 8 {
            Log.audio.error("transcription backlog \(self.pending.count) chunks — inference is slower than capture")
        }
        kickDrain()
    }

    private func kickDrain() {
        guard drainTask == nil else { return }   // a running drain picks up new arrivals itself
        drainTask = Task { @MainActor in
            while !pending.isEmpty {
                let next = pending.removeFirst()
                await ingest(next.samples, start: next.start, speaker: next.speaker, stream: next.stream)
            }
            drainTask = nil
        }
    }

    /// Wait until every queued chunk has been transcribed. Called before the transcript is
    /// finalized so a backlog is finished rather than discarded.
    private func flushPending() async {
        kickDrain()
        while let task = drainTask {
            await task.value
            if pending.isEmpty { break }
            kickDrain()
        }
    }

    /// Lowercased word set; grapheme clusters keep Devanagari matras attached to their letters.
    nonisolated static func tokens(_ t: String) -> Set<String> {
        Set(t.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// Echo handling on the shared clock. System audio never holds ck's voice, so a matching pair
    /// means the mic leaked a remote speaker: the You line goes, the Others line stays. Returns the
    /// new line set, or nil when `new` itself is the dropped You line.
    nonisolated static func applyEcho(_ lines: [MeetingLine], adding new: MeetingLine) -> [MeetingLine]? {
        if new.speaker == "Others" {
            return lines.filter { !($0.speaker == "You" && isEchoOf(new, you: $0)) } + [new]
        }
        if new.speaker == "You", lines.contains(where: { $0.speaker == "Others" && isEchoOf($0, you: new) }) { return nil }
        return lines + [new]
    }

    /// Jaccard similarity of the lowercased word sets (1 = same words, 0 = none shared).
    nonisolated static func jaccard(_ a: String, _ b: String) -> Double {
        let x = tokens(a), y = tokens(b)
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// True when `you` is the mic hearing the speaker: starts within ±1.5 s of `others` on the
    /// shared clock, ≥4 tokens on both sides (short "yeah/okay" pairs never match), Jaccard ≥ 0.8.
    nonisolated static func isEchoOf(_ others: MeetingLine, you: MeetingLine) -> Bool {
        abs(others.start - you.start) <= 1.5 && tokens(others.text).count >= 4 && tokens(you.text).count >= 4
            && jaccard(others.text, you.text) >= 0.8
    }

    nonisolated static func selfTest() {
        func line(_ s: String, _ t0: Double, _ t1: Double) -> MeetingLine {
            MeetingLine(speaker: "x", text: s, start: t0, end: t1)
        }
        precondition(isEchoOf(line("we should add a card for delta global", 7, 12),
                              you: line("We should add a card for delta global.", 8, 13)), "echo not caught")
        precondition(!isEchoOf(line("we should add a card", 7, 12),
                               you: line("now we can go to the call", 7, 12)), "different text flagged")
        precondition(!isEchoOf(line("we should add a card", 0, 5),
                               you: line("we should add a card", 40, 45)), "far-apart lines flagged")
        precondition(!isEchoOf(line("we should add a card", 7, 12),
                               you: line("we should add a card", 9, 14)), "outside 1.5s flagged")
        precondition(!isEchoOf(line("yeah okay right", 7, 9), you: line("yeah okay right", 7, 9)), "3-token pair matched")
        precondition(isEchoOf(line("हम कल मीटिंग में बात करेंगे", 7, 12), you: line("हम कल मीटिंग में बात करेंगे।", 7, 12)), "hindi not matched")
        precondition(tokens("हम कल मीटिंग").count == 3, "hindi tokenisation")
        func spk(_ who: String, _ s: String, _ t: Double) -> MeetingLine { MeetingLine(speaker: who, text: s, start: t, end: t + 5) }
        let txt = "we should add a card for delta"
        let oFirst = applyEcho([spk("Others", txt, 7)], adding: spk("You", txt, 8))
        precondition(oFirst == nil, "You twin not dropped")
        let yFirst = applyEcho([spk("You", txt, 8)], adding: spk("Others", txt, 7))
        precondition(yFirst?.count == 1 && yFirst?.first?.speaker == "Others", "Others not kept / enqueued You not removed")

        // The speech floor must sit in the empty band between noise and speech. These are real
        // maxWindowRMS values from the 11 Aug 2026 meeting: the four chunks that produced
        // "Gracias." / "Thank you." hallucinations, and the quietest chunks that carried actual
        // speech on each stream. A floor that fails either side is the bug coming back.
        // Assert against the calibrated DEFAULT, not the live tunable — a user who follows the
        // documented `defaults write … meetingSpeechFloor` advice must not crash `--selftest`.
        let floor = Float(Settings.defaultMeetingSpeechFloor)
        // Mic chunks 0.00287–0.00925 all returned filler; the 0.01435 system chunk returned ".".
        let hallucinatedNoise: [Float] = [0.00287, 0.00545, 0.00570, 0.00791, 0.00862, 0.00925, 0.01435]
        // Quietest chunks that carried real words: 0.02542 system, 0.03029 mic.
        let realSpeech: [Float] = [0.02542, 0.03029, 0.04511, 0.05176, 0.05944]
        for n in hallucinatedNoise {
            Fixtures.expect(n <= floor, "noise \(n) clears the speech floor \(floor) — Whisper will hallucinate on it")
        }
        for s in realSpeech {
            Fixtures.expect(s > floor, "real speech \(s) falls below the speech floor \(floor) — it would be silently dropped")
        }
        // Mic-dead watchdog: 12 s of near-silence fires once; 12 s of speech never does.
        func fires(_ rms: Float) -> Int {
            var w = MicDeadWatchdog(); var n = 0
            for _ in 0..<48 where w.observe(rms: rms, seconds: 0.25) { n += 1 } // 12 s
            return n
        }
        let silentFires = fires(0.0003), speechFires = fires(0.08)
        precondition(silentFires == 1, "mic watchdog fired \(silentFires)x on 12 s of silence, want 1")
        precondition(speechFires == 0, "mic watchdog fired on speech")
        // Recorder restart: start -> stop -> start (plain path) must deliver buffers both times.
        // Skipped without an input device / mic permission.
        let rec = AudioRecorder()
        do {
            var counts: [Int] = []
            for _ in 0..<2 {
                try rec.start(voiceProcessing: false)
                Thread.sleep(forTimeInterval: 1.0)
                counts.append(rec.diagnostics.appends)
                rec.stop()
            }
            precondition(counts.allSatisfy { $0 > 0 }, "AudioRecorder restart delivered no buffers: \(counts)")
            print("AudioRecorder.restart PASS (appends=\(counts))")
        } catch {
            print("AudioRecorder.restart SKIP (\(describeOSStatus(error)))")
        }
        print("MeetingController.micWatchdog PASS (silence fires=\(silentFires), speech fires=\(speechFires))")
        print("MeetingController.selfTest PASS")
    }

    // MARK: - Chunk ingestion (timeline-stamped)

    private enum Stream { case mic, system }

    private func ingest(_ samples: [Float], start: Double, speaker: String, stream: Stream) async {
        let duration = Double(samples.count) / 16000
        let which = stream == .mic ? "mic" : "others"
        let meanRMS = ResamplingBuffer.rms(samples)
        let peakRMS = ResamplingBuffer.maxWindowRMS(samples)
        Log.audio.info("""
            chunk \(which, privacy: .public) t=\(start, format: .fixed(precision: 1), privacy: .public)s \
            dur=\(duration, format: .fixed(precision: 1), privacy: .public)s \
            meanRMS=\(meanRMS, format: .fixed(precision: 4), privacy: .public) \
            peakRMS=\(peakRMS, format: .fixed(precision: 4), privacy: .public)
            """)
        guard samples.count >= minSamples else {
            Log.audio.info("drop \(which, privacy: .public) t=\(start, format: .fixed(precision: 1), privacy: .public)s — too short (\(samples.count) samples)")
            return
        }
        // Gate on the LOUDEST half-second, not the chunk mean. The old `mean > 0.002` test
        // discarded any chunk where real speech was diluted by surrounding silence — the
        // mechanism behind the multi-minute blank gaps. Both levels are logged so the
        // threshold can be set from real meeting data rather than guessed.
        guard peakRMS > speechPeakRMS else {
            floorDrops += 1
            Log.audio.info("""
                drop \(which, privacy: .public) t=\(start, format: .fixed(precision: 1), privacy: .public)s — \
                below speech floor (peak \(peakRMS, format: .fixed(precision: 4), privacy: .public) \
                <= \(self.speechPeakRMS, format: .fixed(precision: 4), privacy: .public))
                """)
            return
        }
        do {
            let language = meetingLanguage == "auto" ? Settings.languageCode : meetingLanguage
            var raw = try await transcriber.transcribe(samples, language: language, preset: .meeting)
            if Settings.outputMode == "roman" { raw = Transliterate.toLatin(raw) }
            raw = TextProcessor.collapseRepeats(raw) // hallucination loops on short call chunks
            // A meeting is a record, not dictated prose: filler removal deletes real words
            // (and mangles Hindi tokens). Keep only the non-destructive cleanup.
            let text = TextProcessor.process(raw, options: Self.meetingTextOptions)
            guard !text.isEmpty else {
                Log.audio.info("drop \(which, privacy: .public) t=\(start, format: .fixed(precision: 1), privacy: .public)s — empty after cleanup (raw was \(raw.count) chars)")
                return
            }
            // The speech floor cannot catch a loud chunk that is loud with the *other* side's
            // voice bleeding out of the speakers — 16 of these survived the gate on 11 Aug.
            // Whole-line filler only, so real speech containing "thank you" is untouched.
            guard !TextProcessor.isHallucinatedFiller(text, chunkDuration: duration) else {
                Log.audio.info("""
                    drop \(which, privacy: .public) t=\(start, format: .fixed(precision: 1), privacy: .public)s — \
                    whole-line filler "\(text, privacy: .public)" (peak \(peakRMS, format: .fixed(precision: 4), privacy: .public))
                    """)
                return
            }
            let line = MeetingLine(speaker: speaker, text: text, start: start, end: start + duration)
            // Echo dedup. It was off while start times came from two drifting sample counters (it
            // deleted the whole mic stream). On the shared clock the test is tight: only the You
            // line is ever dropped (mic leaking a remote speaker), within ±1.5 s of its Others twin.
            if Settings.meetingEchoDedup {
                guard let merged = Self.applyEcho(lines, adding: line) else {
                    Log.audio.debug("echo drop you \"\(text, privacy: .public)\"")
                    return
                }
                lines = merged
            } else {
                lines.append(line)
            }
            lines.sort { $0.start < $1.start } // interleave You/Others in spoken order
            autosave() // live checkpoint
        } catch {
            Log.audio.error("""
                meeting chunk failed (\(which, privacy: .public) t=\(start, format: .fixed(precision: 1), privacy: .public)s): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    // MARK: - AI summary (BYOK, optional)

    /// Re-probe which backend Summarize would use (Meetings pane calls this on appear).
    func refreshSummaryChoice() async {
        if Snapshot.isRendering { return } // renders pin the state via previewSummaryState
        summaryChoice = await SummaryEngine.resolveLive(for: transcriptText)
    }

    private var transcriptText: String { lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n") }

    /// Snapshot/preview only: put the pane into a given summarise state.
    func previewSummaryState(lines l: [MeetingLine], choice: SummaryChoice?, error: String? = nil) {
        lines = l; summaryChoice = choice; summaryError = error
    }

    func summarize() async {
        guard !lines.isEmpty, !summarizing else { return }
        summarizing = true
        summaryError = nil
        defer { summarizing = false }
        let transcript = transcriptText
        let choice = await SummaryEngine.resolveLive(for: transcript)
        summaryChoice = choice
        guard choice != .none else { summaryError = SummaryEngine.noModelReason(for: transcript); return }
        summarizingWith = choice.label
        do {
            summary = try await SummaryEngine.summarize(transcript: transcript, choice: choice)
            if let url = meetingFile, let summary { MeetingArchive.saveSummary(summary, for: url) }
            autosave()
        } catch {
            summaryError = error.localizedDescription
        }
    }

    // MARK: - Export

    static func mmss(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func exportMarkdown() -> String { Self.markdown(lines: lines, summary: summary) }

    static func markdown(lines: [MeetingLine], summary: String? = nil) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short
        let duration = lines.map(\.end).max() ?? 0
        var speakers: [String] = []
        for l in lines where !speakers.contains(l.speaker) { speakers.append(l.speaker) }
        var md = "# Meeting transcript — \(df.string(from: lines.first?.date ?? Date()))\n"
        md += "Duration: \(mmss(duration)) · \(speakers.joined(separator: " · "))\n\n"
        if let summary, !summary.isEmpty {
            md += summary + "\n\n---\n\n"
        }
        for line in lines {
            md += "[\(mmss(line.start))] **\(line.speaker)**: \(line.text)\n\n"
        }
        return md
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

/// Pure mic-dead detector: fed the RMS of each mic slice, trips once after `limit` seconds of
/// continuous sub-`threshold` audio (buffers arriving, no signal — VPIO with another app on the input).
struct MicDeadWatchdog {
    static let threshold: Float = 0.004
    static let limit = 10.0
    private(set) var quietSeconds = 0.0

    mutating func observe(rms: Float, seconds: Double) -> Bool {
        if rms >= Self.threshold { quietSeconds = 0; return false }
        quietSeconds += seconds
        guard quietSeconds >= Self.limit else { return false }
        quietSeconds = 0
        return true
    }
}
