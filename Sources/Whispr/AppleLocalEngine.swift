import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device cleanup via Apple's Foundation Models (the ~3B Apple Intelligence model, macOS 26+).
/// Zero download, free, fully offline. Unavailable on macOS < 26 or when Apple Intelligence is off —
/// callers fall back to BYOK. All framework use is behind `#available` so the app still runs on macOS 14.
enum AppleLocalEngine {
    static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return true
            default: return false
            }
        }
        #endif
        return false
    }

    /// One-shot completion: `system` becomes the session instructions, `user` the prompt.
    static func complete(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: user)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw LLMError.notConfigured
    }
}
