import SwiftUI
import KeyboardShortcuts

/// First-run wizard. Six steps: welcome → mic → accessibility → model download → try-it → done.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 24) {
            switch model.step {
            case 0: welcome
            case 1: mic
            case 2: accessibility
            case 3: download
            case 4: practice
            default: done
            }
        }
        .padding(40)
        .frame(width: 460, height: 380)
        .onAppear { model.refreshAccessibility() }
    }

    private var welcome: some View {
        step(
            icon: "mic.circle.fill",
            title: "Welcome to Whispr",
            body: "Hold a hotkey, speak, and your words paste at the cursor — transcribed on-device with Whisper. No cloud, no account.",
            button: "Get started",
            action: { model.step = 1 }
        )
    }

    private var mic: some View {
        step(
            icon: model.micGranted ? "checkmark.circle.fill" : "waveform",
            title: "Microphone access",
            body: model.micGranted ? "Microphone access granted." : "Whispr needs the microphone to hear you. Audio is processed locally and never leaves your Mac.",
            button: model.micGranted ? "Continue" : "Allow microphone",
            action: {
                if model.micGranted { model.step = 2 } else { model.requestMic() }
            }
        )
    }

    private var accessibility: some View {
        step(
            icon: model.axGranted ? "checkmark.circle.fill" : "hand.raised.fill",
            title: "Accessibility access",
            body: model.axGranted ? "Accessibility granted — auto-paste is enabled." : "To paste transcripts at your cursor, grant Accessibility. Without it, text is copied to the clipboard and you paste manually.",
            button: model.axGranted ? "Continue" : "Open Accessibility settings",
            action: {
                if model.axGranted { model.step = 3; model.onStartModel() }
                else { model.requestAccessibility() }
            },
            secondary: model.axGranted ? nil : ("Skip for now", { model.step = 3; model.onStartModel() })
        )
    }

    private var download: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Downloading the speech model").font(.title2).bold()
            Text("One-time download (~1.5 GB). This can take a few minutes on first launch.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            ProgressView(value: model.modelReady ? 1 : model.downloadProgress)
                .frame(maxWidth: 320)
            Text(model.modelReady ? "Ready" : "\(Int(model.downloadProgress * 100))%")
                .font(.caption).foregroundStyle(.secondary)
            Button("Continue") { model.step = 4 }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.modelReady)
        }
    }

    private var practice: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.and.mic").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Try it").font(.title2).bold()
            Text("Press the button, say something like “Whispr types what I say”, then stop.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)

            switch model.practice {
            case .idle:
                Button("Start recording") { model.onPracticeStart() }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
            case .recording:
                Button("Stop") { model.onPracticeStop() }
                    .controlSize(.large).keyboardShortcut(.defaultAction).tint(.red)
            case .transcribing:
                ProgressView("Transcribing…")
            case .result(let text):
                GroupBox {
                    Text(text.isEmpty ? "(heard nothing — try again)" : "“\(text)”")
                        .font(.body.italic())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
                HStack {
                    Button("Try again") { model.practice = .idle }
                    Button("Continue") { model.step = 5 }.keyboardShortcut(.defaultAction)
                }
            }

            if case .result = model.practice {} else {
                Button("Skip") { model.step = 5 }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var done: some View {
        step(
            icon: "checkmark.seal.fill",
            title: "You're all set",
            body: "Hold \(Self.hotkeyLabel), speak, then release — your words paste where the cursor is. Change the hotkey or model anytime from the menu-bar icon → Settings.",
            button: "Start using Whispr",
            action: { model.onFinish() }
        )
    }

    private static var hotkeyLabel: String {
        KeyboardShortcuts.getShortcut(for: .dictate).map(String.init(describing:)) ?? "⌘⇧D"
    }

    // Shared step layout.
    private func step(icon: String, title: String, body: String, button: String,
                      action: @escaping () -> Void,
                      secondary: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon).font(.system(size: 52)).foregroundStyle(.tint)
            Text(title).font(.title2).bold()
            Text(body).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(button, action: action).keyboardShortcut(.defaultAction).controlSize(.large)
            if let secondary {
                Button(secondary.0, action: secondary.1).buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
