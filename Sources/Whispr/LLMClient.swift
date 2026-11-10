import Foundation
import Security

/// Minimal BYOK LLM client. Ollama-first: if Ollama runs locally, AI features work fully offline.
/// OpenAI-compatible endpoints (OpenAI / OpenRouter) as the alternative. No SDK — plain URLSession.
enum LLMProvider: String, CaseIterable {
    case ollama, openai, openrouter

    var label: String {
        switch self {
        case .ollama: "Ollama (local)"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        }
    }
}

enum LLMError: Error, LocalizedError {
    case notConfigured, badResponse(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: "No AI model is set up. Turn on Apple Intelligence, install Ollama, or add an API key in AI settings."
        case .badResponse(let s): "AI request failed: \(s)"
        }
    }
}

enum LLMClient {
    // MARK: - Configuration (UserDefaults + Keychain for keys)

    static var provider: LLMProvider {
        get { LLMProvider(rawValue: UserDefaults.standard.string(forKey: "llmProvider") ?? "") ?? .ollama }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "llmProvider") }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: "llmModel") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "llmModel") }
    }

    /// Is Ollama serving locally? (fast probe of /api/tags)
    static func ollamaAlive() async -> Bool {
        var req = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Locally available Ollama model names (empty if not running).
    static func ollamaModels() async -> [String] {
        var req = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    // MARK: - Keychain (API key storage)

    private static let keychainService = "com.ck.whispr.llm"

    static func setAPIKey(_ key: String, for provider: LLMProvider) {
        let account = provider.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func apiKey(for provider: LLMProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Chat

    /// One-shot chat completion via the configured BYOK provider.
    static func complete(system: String, user: String, using chosen: LLMProvider? = nil) async throws -> String {
        let provider = chosen ?? self.provider
        switch provider {
        case .ollama:
            return try await ollamaChat(system: system, user: user)
        case .openai:
            return try await openAIChat(base: "https://api.openai.com/v1", provider: provider, system: system, user: user)
        case .openrouter:
            return try await openAIChat(base: "https://openrouter.ai/api/v1", provider: provider, system: system, user: user)
        }
    }

    /// True if cleanup can run right now via the configured BYOK provider.
    static func available() async -> Bool {
        switch provider {
        case .ollama: return await ollamaAlive()
        case .openai, .openrouter: return apiKey(for: provider)?.isEmpty == false
        }
    }

    static let cleanupPrompt = "You clean up dictated text. Fix punctuation, capitalisation and obvious filler words (um, uh, repeated words). Keep the language and script exactly as given. Never add, remove or reorder content. Reply with only the text."

    /// On-device cleanup: always Ollama (never the OpenAI-compatible path), temperature 0, hard timeout.
    static func ollamaCleanup(_ text: String, model: String, timeout: TimeInterval = 2.5) async throws -> String {
        try await ollamaChat(system: cleanupPrompt, user: text, model: model, timeout: timeout, temperature: 0)
    }

    private static func ollamaChat(system: String, user: String, model override: String? = nil,
                                   timeout: TimeInterval = 120, temperature: Double? = nil) async throws -> String {
        guard await ollamaAlive() else { throw LLMError.notConfigured }
        var name = override ?? model
        let local = await ollamaModels()
        if name.isEmpty || (override == nil && !local.contains(name)) { name = local.first ?? "" }
        guard !name.isEmpty else { throw LLMError.notConfigured }

        var req = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        var body: [String: Any] = [
            "model": name, "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if let temperature { body["options"] = ["temperature": temperature] }
        body["think"] = false
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var (data, resp) = try await URLSession.shared.data(for: req)
        // Older Ollama rejects the `think` key: retry once without it.
        if (resp as? HTTPURLResponse)?.statusCode == 400,
           String(data: data, encoding: .utf8)?.contains("think") == true {
            body.removeValue(forKey: "think")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            (data, resp) = try await URLSession.shared.data(for: req)
        }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              var content = msg["content"] as? String else {
            throw LLMError.badResponse(String(data: data.prefix(200), encoding: .utf8) ?? "unknown")
        }
        if let r = content.range(of: "<think>"), let e = content.range(of: "</think>"), r.lowerBound == content.startIndex || content[..<r.lowerBound].allSatisfy(\.isWhitespace) {
            content.removeSubrange(content.startIndex..<e.upperBound)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openAIChat(base: String, provider: LLMProvider, system: String, user: String) async throws -> String {
        guard let key = apiKey(for: provider), !key.isEmpty else { throw LLMError.notConfigured }
        let name = model.isEmpty ? (provider == .openai ? "gpt-4o-mini" : "openai/gpt-4o-mini") : model

        var req = URLRequest(url: URL(string: "\(base)/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": name,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LLMError.badResponse(String(data: data.prefix(200), encoding: .utf8) ?? "unknown")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
