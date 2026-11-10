import Foundation
import WhisperKit

enum TranscriberError: Error { case notLoaded }

/// Wraps a loaded WhisperKit pipeline. Load once, transcribe many times.
/// An actor: WhisperKit is NOT safe under concurrent inference (preview loop, dictation,
/// meeting chunks, and file import all share this instance) — actor isolation serializes them.
actor Transcriber {
    private var pipe: WhisperKit?
    private(set) var loadedModel: String?

    var isReady: Bool { pipe != nil }

    /// Load a model from an already-downloaded folder (no network).
    /// Load policy: one pipeline per model choice. A repeat call for the already-loaded model
    /// is a no-op, so foreground, onboarding, dictation and meetings never rebuild it
    /// (a rebuild can trigger a CoreML/ANE recompile of ~150 s and ~2 GiB of disk writes).
    private var loading: Task<Void, Error>?

    func load(model: String, folder: URL) async throws {
        // Serialise: wait out any in-flight load (its error is that caller's), then re-check.
        while let inflight = loading { _ = try? await inflight.value }
        if pipe != nil, loadedModel == model { return }
        let task = Task { try await self.doLoad(model: model, folder: folder) }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func doLoad(model: String, folder: URL) async throws {
        let fm = FileManager.default
        let compiled = (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".mlmodelc") } ?? []
        Log.app.info("model load start: \(model, privacy: .public) folderExists=\(fm.fileExists(atPath: folder.path)) mlmodelc=\(compiled.count)")
        let t0 = Date()
        let warmKey = "\(model)|\(Self.osBuild)"
        let prewarm = Self.needsPrewarm(warmKey: warmKey, lastWarm: UserDefaults.standard.string(forKey: Self.lastWarmKey))
        let pipe = try await WhisperKit(
            modelFolder: folder.path,
            verbose: false,
            prewarm: prewarm,
            load: true,
            download: false
        )
        self.pipe = pipe
        self.loadedModel = model
        UserDefaults.standard.set(warmKey, forKey: Self.lastWarmKey)
        Log.app.info("model load done: \(model, privacy: .public) prewarm=\(prewarm) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    }

    /// Prewarm (load-unload-load per component) caps peak memory while Core ML specialises a
    /// model for the ANE, but doubles a cache-hit load (turbo: 1.9 s vs 1.0 s measured with
    /// --load-test). The specialised cache is keyed by OS build (~/Library/Caches/<bundle id>/
    /// com.apple.e5rt.e5bundlecache/<build>), not by code signature or app path — a rebuild or a
    /// moved copy did not recompile. So prewarm only for a model never loaded on this OS build.
    static let lastWarmKey = "lastWarmModel"
    static func needsPrewarm(warmKey: String, lastWarm: String?) -> Bool { warmKey != lastWarm }

    static var osBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func selfTest() {
        precondition(needsPrewarm(warmKey: "turbo|25E253", lastWarm: nil), "first load prewarms")
        precondition(!needsPrewarm(warmKey: "turbo|25E253", lastWarm: "turbo|25E253"), "same model+OS skips prewarm")
        precondition(needsPrewarm(warmKey: "turbo|25F10", lastWarm: "turbo|25E253"), "OS update prewarms")
        precondition(needsPrewarm(warmKey: "base|25E253", lastWarm: "turbo|25E253"), "model switch prewarms")
        precondition(!osBuild.isEmpty, "kern.osversion readable")
        print("Transcriber prewarm selftest: 4 cases PASS (osBuild=\(osBuild))")
    }

    /// Dictation is a few seconds of one close voice; a meeting chunk is up to 30 s of
    /// possibly-quiet remote speech. The thresholds that suit the first discard the second.
    enum Preset { case dictation, meeting }

    /// Transcribe 16 kHz mono Float32 samples to plain text. `language` nil = auto-detect.
    func transcribe(_ samples: [Float], language: String? = nil, preset: Preset = .dictation) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: Self.options(language, preset))
        return Self.join(results)
    }

    /// Transcribe an audio file (WhisperKit resamples internally). Used by the headless gates and file import.
    func transcribeFile(_ path: String, language: String? = nil) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        let results = try await pipe.transcribe(audioPath: path, decodeOptions: Self.options(language, .meeting))
        return Self.join(results)
    }

    private static func options(_ language: String?, _ preset: Preset = .dictation) -> DecodingOptions {
        var opts = DecodingOptions()
        opts.language = language
        // `detectLanguage` defaults to `!usePrefillPrompt`, and usePrefillPrompt is true — so
        // "auto" (language == nil) was running with NO detection pass and no language token,
        // which is how an English meeting produced a line of Portuguese. Ask for it explicitly.
        opts.detectLanguage = (language == nil)
        // Whisper's built-in any-language → English translation
        if Settings.outputMode == "translate" { opts.task = .translate }

        if preset == .meeting {
            // 5 fallbacks on a 30 s chunk costs seconds of wall clock; 3 still breaks loops.
            opts.temperatureFallbackCount = 3
            // 2.4 rejects legitimately repetitive meeting speech ("correct, correct").
            opts.compressionRatioThreshold = 2.6
            // -1.0 discarded quiet remote speech as low-confidence — the "Others" side is
            // played through speakers and arrives far below mic level.
            opts.logProbThreshold = -1.2
            opts.noSpeechThreshold = 0.7
        }
        return opts
    }

    private static func join(_ results: [TranscriptionResult]) -> String {
        results.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
