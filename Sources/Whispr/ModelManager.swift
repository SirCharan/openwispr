import Foundation
import WhisperKit

/// Tracks the selected Whisper model and ensures it is downloaded locally.
/// Downloads are cached by WhisperKit, so `ensureDownloaded` is idempotent across launches.
@MainActor
final class ModelManager {
    static let defaultModel = "large-v3-v20240930_turbo"

    /// Offered in the Models pane. Smaller = faster download / lower RAM / lower accuracy.
    static let available = [
        "large-v3-v20240930_turbo", // ~1.5 GB, best accuracy/speed on Apple Silicon
        "large-v3-v20240930_626MB", // compressed large
        "small",
        "base",
        "tiny",
    ]

    private let key = "selectedModel"

    var selectedModel: String {
        get { UserDefaults.standard.string(forKey: key) ?? Self.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Download the model if not already cached. `progress` reports 0.0…1.0 on the main actor.
    /// Returns the local model folder to hand to `Transcriber.load`.
    func ensureDownloaded(_ model: String, progress: @escaping (Double) -> Void) async throws -> URL {
        try await WhisperKit.download(variant: model, progressCallback: { p in
            Task { @MainActor in progress(p.fractionCompleted) }
        })
    }
}
