import SwiftUI
import KeyboardShortcuts

/// Settings surface: rebind hotkey, switch model (live reload), copy-only toggle,
/// launch-at-login, and Accessibility status.
struct SettingsView: View {
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage("removeFillers") private var removeFillers = true
    @AppStorage("cleanUp") private var cleanUp = true
    @AppStorage("handsFree") private var handsFree = false
    @AppStorage("language") private var language = "auto"
    @State private var selectedModel: String
    @State private var launchAtLogin: Bool
    @State private var accessibilityOK: Bool

    private let models: [String]
    private let onReloadModel: (String) -> Void

    init(currentModel: String, models: [String], onReloadModel: @escaping (String) -> Void) {
        _selectedModel = State(initialValue: currentModel)
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
        _accessibilityOK = State(initialValue: Permissions.hasAccessibility)
        self.models = models
        self.onReloadModel = onReloadModel
    }

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            DictionaryView().tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            SnippetsView().tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            HistoryView().tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            PerAppView().tabItem { Label("Apps", systemImage: "app.badge") }
        }
        .frame(width: 500, height: 480)
    }

    private var general: some View {
        Form {
            Section("Dictation hotkey") {
                KeyboardShortcuts.Recorder("Shortcut:", name: .dictate)
                Toggle("Hands-free (tap to start, tap to stop)", isOn: $handsFree)
                Text(handsFree ? "Tap the hotkey to start, tap again to stop."
                               : "Hold the hotkey to talk, release to transcribe.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model") {
                Picker("Whisper model", selection: $selectedModel) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: selectedModel) { _, new in onReloadModel(new) }
                Text("Switching downloads the model if needed, then reloads.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Language", selection: $language) {
                    ForEach(Languages.list, id: \.code) { lang in
                        Text(lang.name).tag(lang.code ?? "auto")
                    }
                }
            }
            Section("Behavior") {
                Toggle("Auto-paste at cursor (off = copy to clipboard only)", isOn: $autoPaste)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
            }
            Section("Transcript cleanup") {
                Toggle("Remove filler words (um, uh, er)", isOn: $removeFillers)
                Toggle("Capitalize sentences & tidy spacing", isOn: $cleanUp)
            }
            Section("Permissions") {
                HStack {
                    Text(accessibilityOK
                         ? "Accessibility: granted ✓"
                         : "Accessibility needed for auto-paste")
                    Spacer()
                    if !accessibilityOK {
                        Button("Grant…") {
                            Permissions.requestAccessibility()
                            accessibilityOK = Permissions.hasAccessibility
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
