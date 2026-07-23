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

    /// Transcribe 16 kHz mono Float32 samples to plain text.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        let results = try await pipe.transcribe(audioArray: samples)
        return Self.join(results)
    }

    /// Transcribe an audio file (WhisperKit resamples internally). Used by the M3 gate.
    func transcribeFile(_ path: String) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        let results = try await pipe.transcribe(audioPath: path)
        return Self.join(results)
    }

    private static func join(_ results: [TranscriptionResult]) -> String {
        results.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
