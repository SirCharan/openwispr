import Foundation
import WhisperKit

enum TranscriberError: Error { case notLoaded }

/// Wraps a loaded WhisperKit pipeline. Load once, transcribe many times.
final class Transcriber {
    private var pipe: WhisperKit?
    private(set) var loadedModel: String?

    var isReady: Bool { pipe != nil }

    /// Load a model from an already-downloaded folder (no network).
    func load(model: String, folder: URL) async throws {
        let pipe = try await WhisperKit(
            modelFolder: folder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        self.pipe = pipe
        self.loadedModel = model
    }

    /// Transcribe 16 kHz mono Float32 samples to plain text. `language` nil = auto-detect.
    func transcribe(_ samples: [Float], language: String? = nil) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: Self.options(language))
        return Self.join(results)
    }

    /// Transcribe an audio file (WhisperKit resamples internally). Used by the M3 gate.
    func transcribeFile(_ path: String, language: String? = nil) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        let results = try await pipe.transcribe(audioPath: path, decodeOptions: Self.options(language))
        return Self.join(results)
    }

    private static func options(_ language: String?) -> DecodingOptions {
        var opts = DecodingOptions()
        opts.language = language
        return opts
    }

    private static func join(_ results: [TranscriptionResult]) -> String {
        results.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
