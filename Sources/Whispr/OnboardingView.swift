import SwiftUI
import KeyboardShortcuts
import AVFoundation

/// First-run wizard, twelve steps: welcome → move → mic → mic-test → accessibility →
/// hotkey-test → screen recording → model download → setup → try-it → personalize → done.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @State private var launchAtLogin = false
    @State private var loginItemFailed = false
    @State private var smartCleanup = Settings.smartCleanup
    @AppStorage("hotkeyMode") private var hotkeyMode = "fn"

    // 4 phases, mapped monotonically by step index.
    private let phases = ["Permissions", "Set up", "Try it", "Done"]
    private func phaseIndex(_ step: Int) -> Int {
        switch step { case 0...6: 0; case 7...8: 1; case 9...10: 2; default: 3 }
    }

    var body: some View {
        VStack(spacing: 18) {
            stepper
            VStack(spacing: 20) {
                switch model.step {
                case 0: welcome
                case 1: move
                case 2: mic
                case 3: MicTestStep(onContinue: { model.step = 4 })
                case 4: accessibility
                case 5: HotkeyTestStep(hotkeyMode: $hotkeyMode, onContinue: { model.step = 6 })
                case 6: screenRecording
                case 7: download
                case 8: setup
                case 9: practice
                case 10: PersonalizeStep(onContinue: { model.step = 11 })
                default: done
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(32)
        .frame(width: 480, height: 480)
        .background(Brand.bg)
        .tint(Brand.coral)
        .preferredColorScheme(.light) // Paper Studio chrome, consistent with the home window
        .onAppear { model.refreshAccessibility() }
    }

    private var stepper: some View {
        let active = phaseIndex(model.step)
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(phases.enumerated()), id: \.offset) { i, name in
                    Text(name.uppercased())
                        .font(.system(size: 10, weight: i == active ? .bold : .medium, design: .monospaced))
                        .foregroundStyle(i == active ? Brand.coral : (i < active ? Brand.text : Brand.muted))
                    if i < phases.count - 1 {
                        Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(Brand.muted)
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.line).frame(height: 3)
                    Capsule().fill(Brand.coral)
                        .frame(width: geo.size.width * CGFloat(active + 1) / CGFloat(phases.count), height: 3)
                }
            }
            .frame(height: 3)
        }
    }

    private var welcome: some View {
        step(
            icon: "mic.circle.fill",
            title: "Welcome to OpenWispr",
            body: "Hold a hotkey, speak, and your words paste at the cursor — transcribed on-device with Whisper. No cloud, no account.",
            button: "Get started",
            action: { model.step = model.needsMove ? 1 : 2 }
        )
    }

    private var move: some View {
        step(
            icon: "arrow.down.app.fill",
            title: "Move to Applications",
            body: "OpenWispr is running from \(Bundle.main.bundlePath.hasPrefix("/Volumes") ? "the disk image" : "outside Applications"). Moving it to the Applications folder keeps macOS permissions stable. OpenWispr will relaunch after the move.",
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
                : model.micDenied ? "Microphone access was denied. Open System Settings → Privacy & Security → Microphone and turn OpenWispr on, then come back."
                : "OpenWispr needs the microphone to hear you. Audio is processed locally and never leaves your Mac.",
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
                : "OpenWispr needs Accessibility for the fn dictation key AND to paste at your cursor. Without it the app can't hear the trigger.",
            button: model.axGranted ? "Continue" : "Open Accessibility settings",
            action: {
                if model.axGranted { model.step = 5 }
                else { model.requestAccessibility() }
            },
            // fn trigger dies without AX — only allow skipping when a custom shortcut is the trigger
            secondary: (model.axGranted || hotkeyMode == "fn") ? nil : ("Skip for now", { model.step = 5 })
        )
    }

    private var screenRecording: some View {
        step(
            icon: (model.screenRecGranted || model.screenRecPrompted) ? "checkmark.circle.fill" : "rectangle.inset.filled.badge.record",
            title: "Meeting capture (optional)",
            body: model.screenRecGranted
                ? "Screen & System Audio Recording granted — meetings are ready."
                : model.screenRecPrompted
                ? "Requested. After you enable OpenWispr in System Settings, macOS applies it on the next launch — continue setup now."
                : "OpenWispr can transcribe calls: your mic plus the other side's audio. macOS exposes system audio through Screen Recording permission. Only audio is used. Skip if you only dictate.",
            button: (model.screenRecGranted || model.screenRecPrompted) ? "Continue" : "Enable meeting capture",
            action: {
                if model.screenRecGranted || model.screenRecPrompted { model.step = 7; model.onStartModel() }
                else { model.requestScreenRecording() }
            },
            secondary: ("Skip — dictation only", { model.step = 7; model.onStartModel() })
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
                Button("Continue") { model.step = 8 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.modelReady)
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
                Toggle("Start OpenWispr at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if LoginItem.set(on) { loginItemFailed = false }
                        else { launchAtLogin = false; loginItemFailed = true }
                    }
                if AppleLocalEngine.isAvailable() {
                    Toggle("Smart cleanup — fix grammar & formatting on-device", isOn: $smartCleanup)
                        .onChange(of: smartCleanup) { _, on in
                            Settings.smartCleanup = on
                            if on, Settings.rewriteStyle == "off" { Settings.rewriteStyle = "clean" }
                        }
                }
            }
            .formStyle(.columns)
            .frame(maxWidth: 320)
            Text(loginItemFailed ? "Couldn't set launch-at-login — move OpenWispr to Applications first."
                 : hotkeyMode == "fn" ? "Tip: set System Settings → Keyboard → “Press 🌐 key to” = Do Nothing."
                 : "Everything can be changed later in Settings.")
                .font(.caption).foregroundStyle(loginItemFailed ? .orange : .secondary)
            Button("Continue") { model.step = 9 }.keyboardShortcut(.defaultAction).controlSize(.large)
        }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    private var practice: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.and.mic").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Try it").font(.title2).bold()
            Text("Press the button, say something like “OpenWispr types what I say”, then stop.")
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
                    Button("Continue") { model.step = 10 }.keyboardShortcut(.defaultAction)
                }
            }

            if case .result = model.practice {} else {
                Button("Skip") { model.step = 10 }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var done: some View {
        step(
            icon: "checkmark.seal.fill",
            title: "You're all set",
            body: "Hold \(Self.hotkeyLabel), speak, then release — your words paste where the cursor is. Change the hotkey or model anytime from the menu-bar icon → Settings.",
            button: "Start using OpenWispr",
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

// MARK: - Live mic test ("do the bars move when you speak?")

private struct MicTestStep: View {
    let onContinue: () -> Void
    @StateObject private var meter = MicLevelMeter()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Test your microphone").font(.title2).bold()
            Text("Say a few words — do the bars move?")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(0..<14, id: \.self) { i in
                    Capsule()
                        .fill(Double(i) / 14 < meter.level ? Brand.coral : Brand.line)
                        .frame(width: 7, height: 34)
                }
            }
            .frame(height: 40)
            .padding(.vertical, 6)
            .animation(.easeOut(duration: 0.08), value: meter.level)
            HStack(spacing: 12) {
                Button("Change microphone") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!)
                }
                Button("Yes, looks good") { onContinue() }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
    }
}

// MARK: - Hotkey press-test ("does it light up when you press it?")

private struct HotkeyTestStep: View {
    @Binding var hotkeyMode: String
    let onContinue: () -> Void
    @State private var monitor: ModifierKeyMonitor?
    @State private var lit = false
    @State private var everFired = false

    private var isModifier: Bool { hotkeyMode != "custom" }
    private var label: String { Triggers.trigger(for: hotkeyMode).label }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Test the dictation key").font(.title2).bold()
            if isModifier {
                Text("Press and hold the \(label) key — does it light up?")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .frame(width: 120, height: 76)
                    .background(RoundedRectangle(cornerRadius: 14).fill(lit ? Brand.coral.opacity(0.25) : Brand.surface))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(lit ? Brand.coral : Brand.line, lineWidth: lit ? 2 : 1))
                    .animation(.easeOut(duration: 0.1), value: lit)
                Text(everFired ? "Detected — you're good." : "Nothing yet? Accessibility may be off (previous step).")
                    .font(.caption).foregroundStyle(everFired ? Brand.coral : .secondary)
                HStack(spacing: 12) {
                    Picker("", selection: $hotkeyMode) {
                        ForEach(Triggers.list, id: \.id) { t in Text(t.label).tag(t.id) }
                        Text("Custom").tag("custom")
                    }
                    .labelsHidden().frame(maxWidth: 130)
                    .onChange(of: hotkeyMode) { _, _ in
                        NotificationCenter.default.post(name: .whisprHotkeyModeChanged, object: nil)
                        everFired = false; lit = false; attach()
                    }
                    Button("Continue") { onContinue() }.keyboardShortcut(.defaultAction).controlSize(.large)
                }
            } else {
                Text("You've chosen a custom shortcut. Set it below, then test it live once setup finishes.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                KeyboardShortcuts.Recorder("Shortcut:", name: .dictate)
                Button("Continue") { onContinue() }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .onAppear { attach() }
        .onDisappear { monitor = nil }
    }

    private func attach() {
        guard isModifier else { monitor = nil; return }
        monitor = ModifierKeyMonitor(
            trigger: Triggers.trigger(for: hotkeyMode),
            onKeyDown: { lit = true; everFired = true },
            onKeyUp: { lit = false }
        )
    }
}

// MARK: - Personalize (speed + time saved)

private struct PersonalizeStep: View {
    let onContinue: () -> Void
    @State private var typingHours = 3.0

    var body: some View {
        VStack(spacing: 18) {
            Text("Speaking is ~4× faster").font(.title2).bold()
            HStack(spacing: 16) {
                speedBar("Typing", "≈40 wpm", 0.25, Brand.line)
                speedBar("Your voice", "≈150 wpm", 1.0, Brand.coral)
            }
            Divider().frame(maxWidth: 240)
            Text("If you type about \(Int(typingHours))h a day, OpenWispr could save you")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("\(Int(OnboardingModel.hoursSavedPerWeek(typingHoursPerDay: typingHours).rounded())) hours a week")
                .font(.system(size: 30, weight: .bold, design: .serif)).foregroundStyle(Brand.coral)
            Slider(value: $typingHours, in: 1...8, step: 1).frame(maxWidth: 260)
            Button("Continue") { onContinue() }.keyboardShortcut(.defaultAction).controlSize(.large)
        }
    }

    private func speedBar(_ title: String, _ sub: String, _ frac: CGFloat, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption.bold())
            RoundedRectangle(cornerRadius: 6).fill(color).frame(width: 90 * max(0.25, frac), height: 18)
                .frame(width: 90, alignment: .leading)
            Text(sub).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}
