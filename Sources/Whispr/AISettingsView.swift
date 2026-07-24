import SwiftUI

/// AI (BYOK) configuration: provider, model, API key (Keychain), live status probe.
struct AISettingsView: View {
    @State private var provider = LLMClient.provider
    @State private var model = LLMClient.model
    @State private var apiKey = ""
    @State private var status = "checking…"
    @State private var ollamaModels: [String] = []

    var body: some View {
        Form {
            Section("Provider") {
                Picker("AI provider", selection: $provider) {
                    ForEach(LLMProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: provider) { _, new in
                    LLMClient.provider = new
                    apiKey = LLMClient.apiKey(for: new) ?? ""
                    Task { await probe() }
                }
                HStack {
                    Text("Status:")
                    Text(status).foregroundStyle(status.hasPrefix("ready") ? .green : .secondary)
                    Spacer()
                    Button("Check") { Task { await probe() } }
                }.font(.caption)
            }

            if provider == .ollama {
                Section("Ollama") {
                    if ollamaModels.isEmpty {
                        Text("Ollama not detected on localhost:11434. Install from ollama.com and `ollama pull llama3.2`.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $model) {
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: model) { _, new in LLMClient.model = new }
                    }
                }
            } else {
                Section("API key (stored in Keychain)") {
                    SecureField("sk-…", text: $apiKey)
                        .onSubmit { LLMClient.setAPIKey(apiKey, for: provider) }
                    TextField("Model (blank = gpt-4o-mini · OpenRouter: openai/gpt-4o-mini)", text: $model)
                        .onSubmit { LLMClient.model = model }
                    Button("Save") {
                        LLMClient.setAPIKey(apiKey, for: provider)
                        LLMClient.model = model
                        Task { await probe() }
                    }
                }
            }

            Section {
                Text("AI is optional. Dictation and meetings work fully without it. With Ollama, summaries and rewrites run 100% on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            apiKey = LLMClient.apiKey(for: provider) ?? ""
            await probe()
        }
    }

    private func probe() async {
        status = "checking…"
        if provider == .ollama {
            ollamaModels = await LLMClient.ollamaModels()
            if model.isEmpty, let first = ollamaModels.first { model = first; LLMClient.model = first }
            status = ollamaModels.isEmpty ? "Ollama not running" : "ready (\(ollamaModels.count) models)"
        } else {
            status = await LLMClient.available() ? "ready (key saved)" : "no API key"
        }
    }
}
