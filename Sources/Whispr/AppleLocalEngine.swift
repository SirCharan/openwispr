import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (Foundation Models, macOS 26+, Apple Intelligence). Free, offline, no key.
/// Used for meeting Summarize only — dictation cleanup stays Ollama-only. All framework use sits
/// behind `#available`, so the app still launches on macOS 14.
enum AppleLocalEngine {
    /// Live availability: `ready` is true only when the model can answer right now.
    static func status() -> (ready: Bool, text: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, "On-device, ready")
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return (false, "Turn on Apple Intelligence in System Settings")
                case .deviceNotEligible: return (false, "Not supported on this Mac")
                case .modelNotReady: return (false, "Apple Intelligence model is still downloading")
                @unknown default: return (false, "Unavailable (\(reason))")
                }
            }
        }
        #endif
        return (false, "Not supported on this Mac")
    }

    static func isAvailable() -> Bool { status().ready }

    /// Whether the on-device model can read this language. Unknown stays true so the runtime retry in SummaryEngine decides.
    static func supports(language code: String) -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.supportsLocale(Locale(identifier: code))
        }
        #endif
        return ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"].contains(String(code.prefix(2)))
    }

    /// One-shot completion: `system` becomes the session instructions, `user` the prompt.
    static func complete(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: user)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw LLMError.notConfigured
    }
}
