import SwiftUI
import KeyboardShortcuts
import AVFoundation

/// First-run wizard, nine steps: welcome → move-to-Applications → mic → accessibility →
/// screen recording (optional) → model download → try-it → setup (hotkey + login) → done.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @State private var launchAtLogin = false
    @AppStorage("hotkeyMode") private var hotkeyMode = "fn"

    var body: some View {
        VStack(spacing: 24) {
            switch model.step {
            case 0: welcome
            case 1: move
            case 2: mic
            case 3: accessibility
            case 4: screenRecording
            case 5: download
            case 6: practice
            case 7: setup
            default: done
            }
        }
        .padding(40)
        .frame(width: 460, height: 420)
        .onAppear { model.refreshAccessibility() }
    }

    private var welcome: some View {
        step(
            icon: "mic.circle.fill",
            title: "Welcome to Whispr",
            body: "Hold a hotkey, speak, and your words paste at the cursor — transcribed on-device with Whisper. No cloud, no account.",
            button: "Get started",
            action: { model.step = model.needsMove ? 1 : 2 }
        )
    }

    private var move: some View {
        step(
            icon: "arrow.down.app.fill",
            title: "Move to Applications",
            body: "Whispr is running from \(Bundle.main.bundlePath.hasPrefix("/Volumes") ? "the disk image" : "outside Applications"). Moving it to the Applications folder keeps macOS permissions stable. Whispr will relaunch after the move.",
            button: "Move to Applications",
            action: { model.onMoveToApplications() },
            secondary: ("Skip", { model.step = 2 })
        )
    }

    private var mic: some View {
        step(
            icon: model.micGranted ? "checkmark.circle.fill" : "waveform",
            title: "Microphone access",
            body: model.micGranted ? "Microphone access granted."
                : model.micDenied ? "Microphone access was denied. Open System Settings → Privacy & Security → Microphone and turn Whispr on, then come back."
                : "Whispr needs the microphone to hear you. Audio is processed locally and never leaves your Mac.",
            button: model.micGranted ? "Continue" : model.micDenied ? "Open System Settings" : "Allow microphone",
            action: {
                if model.micGranted { model.step = 3 }
                else if model.micDenied { model.openMicSettings() }
                else { model.requestMic() }
            },
            secondary: model.micDenied ? ("I've enabled it — re-check", { model.micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }) : nil
        )
    }

    private var accessibility: some View {
        step(
            icon: model.axGranted ? "checkmark.circle.fill" : "hand.raised.fill",
            title: "Accessibility access",
            body: model.axGranted ? "Accessibility granted — the fn trigger and auto-paste are enabled."
                : "Whispr needs Accessibility for the fn dictation key AND to paste at your cursor. Without it the app can't hear the trigger.",
            button: model.axGranted ? "Continue" : "Open Accessibility settings",
            action: {
                if model.axGranted { model.step = 4 }
                else { model.requestAccessibility() }
            },
            // fn trigger dies without AX — only allow skipping when a custom shortcut is the trigger
            secondary: (model.axGranted || hotkeyMode == "fn") ? nil : ("Skip for now", { model.step = 4 })
        )
    }

    private var screenRecording: some View {
        step(
            icon: (model.screenRecGranted || model.screenRecPrompted) ? "checkmark.circle.fill" : "rectangle.inset.filled.badge.record",
            title: "Meeting capture (optional)",
            body: model.screenRecGranted
                ? "Screen & System Audio Recording granted — meetings are ready."
                : model.screenRecPrompted
                ? "Requested. After you enable Whispr in System Settings, macOS applies it on the next launch — continue setup now."
                : "Whispr can transcribe calls: your mic plus the other side's audio. macOS exposes system audio through Screen Recording permission. Only audio is used. Skip if you only dictate.",
            button: (model.screenRecGranted || model.screenRecPrompted) ? "Continue" : "Enable meeting capture",
            action: {
                if model.screenRecGranted || model.screenRecPrompted { model.step = 5; model.onStartModel() }
                else { model.requestScreenRecording() }
            },
            secondary: ("Skip — dictation only", { model.step = 5; model.onStartModel() })
        )
    }

    private var download: some View {
        VStack(spacing: 20) {
            Image(systemName: model.modelError == nil ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 52)).foregroundStyle(model.modelError == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
            Text("Downloading the speech model").font(.title2).bold()
            if let err = model.modelError {
                Text("Download failed: \(err)\nCheck your connection and retry.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Retry") { model.modelError = nil; model.onStartModel() }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            } else {
                Text("One-time download (~1.5 GB). This can take a few minutes on first launch.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                ProgressView(value: model.modelReady ? 1 : model.downloadProgress)
                    .frame(maxWidth: 320)
                Text(model.modelReady ? "Ready" : "\(Int(model.downloadProgress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Continue") { model.step = 6 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.modelReady)
            }
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
                    Button("Continue") { model.step = 7 }.keyboardShortcut(.defaultAction)
                }
            }

            if case .result = model.practice {} else {
                Button("Skip") { model.step = 7 }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var setup: some View {
        VStack(spacing: 20) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Make it yours").font(.title2).bold()
            Form {
                Picker("Dictation trigger:", selection: $hotkeyMode) {
                    ForEach(Triggers.list, id: \.id) { t in Text(t.label).tag(t.id) }
                    Text("Custom shortcut").tag("custom")
                }
                .onChange(of: hotkeyMode) { _, _ in NotificationCenter.default.post(name: .whisprHotkeyModeChanged, object: nil) }
                if hotkeyMode == "custom" {
                    KeyboardShortcuts.Recorder("Shortcut:", name: .dictate)
                }
                Toggle("Start Whispr at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
            }
            .formStyle(.columns)
            .frame(maxWidth: 320)
            Text(hotkeyMode == "fn"
                 ? "Tip: set System Settings → Keyboard → “Press 🌐 key to” = Do Nothing."
                 : "Everything can be changed later in Settings.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Continue") { model.step = 8 }.keyboardShortcut(.defaultAction).controlSize(.large)
        }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
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

    private static var hotkeyLabel: String { AppController.hotkeyHint }

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
