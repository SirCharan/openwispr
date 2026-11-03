import SwiftUI
import KeyboardShortcuts
import AVFoundation

/// First-run wizard (v0.15): Paper Studio + Wispr Flow patterns.
/// welcome → personalize → move? → permissions+mic VU → model → trigger+press-test → practice → done
/// A returning install (stats survived in Application Support) gets a "welcome back" greeting instead.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @State private var launchAtLogin = false
    @State private var loginItemFailed = false
    @State private var typingHours = 2.0
    @AppStorage("hotkeyMode") private var hotkeyMode = "fn"

    /// 3 phases mapped by step.
    private let phases = ["Set up", "Model", "Dictate"]
    private func phaseIndex(_ step: OnboardingModel.Step) -> Int {
        if step <= .permissions { 0 } else if step == .download { 1 } else { 2 }
    }

    var body: some View {
        VStack(spacing: 0) {
            stepper
                .padding(.bottom, 20)
            VStack(spacing: 0) {
                switch model.step {
                case .welcome: welcome
                case .personalize: personalize
                case .move: move
                case .permissions: PermissionsStep(
                    model: model,
                    hotkeyMode: hotkeyMode,
                    onContinue: {
                        model.step = .download
                        model.startModelIfNeeded()
                    }
                )
                case .download: download
                case .trigger: TriggerStep(
                    hotkeyMode: $hotkeyMode,
                    launchAtLogin: $launchAtLogin,
                    loginItemFailed: $loginItemFailed,
                    onContinue: { model.step = .practice }
                )
                case .practice: PracticeStep(model: model, hotkeyMode: hotkeyMode)
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(36)
        .frame(width: 520, height: 560)
        .background(Brand.bg)
        .tint(Brand.coral)
        .onAppear {
            model.refreshAccessibility()
            launchAtLogin = LoginItem.isEnabled
        }
    }

    // MARK: - Stepper

    private var stepper: some View {
        let active = phaseIndex(model.step)
        return VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(phases.enumerated()), id: \.offset) { i, name in
                    HStack(spacing: 6) {
                        Text(name)
                            .font(Brand.caption.weight(i == active ? .semibold : .medium))
                            .foregroundStyle(i == active ? Brand.coral : (i < active ? Brand.text : Brand.muted))
                        if i < phases.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(Brand.caption.weight(.semibold))
                                .foregroundStyle(Brand.muted.opacity(0.7))
                        }
                    }
                    if i < phases.count - 1 { Spacer(minLength: 4) }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.line).frame(height: 3)
                    Capsule().fill(Brand.coral)
                        .frame(width: max(8, geo.size.width * CGFloat(active + 1) / CGFloat(phases.count)), height: 3)
                        .animation(.easeOut(duration: 0.25), value: active)
                }
            }
            .frame(height: 3)
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        Group {
            if model.returning {
                stepShell(
                    icon: "arrow.clockwise.heart.fill",
                    title: "Welcome back",
                    body: "Your words and streak survived the reinstall. Two quick grants and a fresh model download, and you're dictating again.",
                    primary: ("Pick up where I left off", {
                        model.startModelIfNeeded()
                        model.step = model.needsMove ? .move : .permissions
                    })
                ) {
                    HStack(spacing: 16) {
                        chip("\(model.restoredWords.formatted()) words")
                        if model.restoredStreak > 0 { chip("\(model.restoredStreak)-day best streak") }
                    }
                    .padding(.top, 4)
                }
            } else {
                stepShell(
                    icon: "mic.circle.fill",
                    title: "Welcome to OpenWispr",
                    body: "Hold a hotkey, speak, and clean text pastes at the cursor — transcribed on-device with Whisper.",
                    primary: ("Get started", {
                        // Overlap model load with the rest of setup when possible
                        model.startModelIfNeeded()
                        model.step = .personalize
                    })
                ) {
                    HStack(spacing: 16) {
                        chip("On-device")
                        chip("No account")
                        chip("No cloud")
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var personalize: some View {
        stepShell(
            icon: "keyboard.badge.ellipsis",
            title: "How much do you type?",
            body: "Ballpark hours a day, across email, docs, and chat.",
            primary: ("Sounds good", { model.step = model.needsMove ? .move : .permissions })
        ) {
            VStack(spacing: 14) {
                Picker("", selection: $typingHours) {
                    Text("1h").tag(1.0)
                    Text("2h").tag(2.0)
                    Text("4h").tag(4.0)
                    Text("6h").tag(6.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                Text("Speaking is ~4× faster — that's ~\(Int(OnboardingModel.hoursSavedPerWeek(typingHoursPerDay: typingHours).rounded())) hours back every week.")
                    .font(Brand.body.weight(.medium))
                    .foregroundStyle(Brand.coral)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.2), value: typingHours)
            }
            .padding(.top, 6)
        }
    }

    private var move: some View {
        stepShell(
            icon: "arrow.down.app.fill",
            title: "Move to Applications",
            body: "OpenWispr is running from \(Bundle.main.bundlePath.hasPrefix("/Volumes") ? "the disk image" : "outside Applications"). Moving it keeps macOS permissions stable. It will relaunch after the move.",
            primary: ("Move to Applications", { model.onMoveToApplications() }),
            secondary: ("Skip for now", { model.step = .permissions })
        )
    }

    private var download: some View {
        VStack(spacing: 22) {
            iconBadge(model.modelError == nil
                      ? (model.modelReady ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                      : "exclamationmark.triangle.fill",
                      tint: model.modelError == nil ? Brand.coral : Brand.warn)
            Text(model.modelReady ? "Speech model ready" : "Downloading the speech model")
                .font(Brand.title)
                .foregroundStyle(Brand.text)
            if let err = model.modelError {
                Text("Download failed: \(err)\nCheck your connection and try again.")
                    .font(Brand.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.muted)
                    .frame(maxWidth: 360)
                Button("Retry") { model.retryModel() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Text(model.modelReady
                      ? "Already on this Mac — no download needed."
                      : "One-time download (~1.5 GB). Usually a few minutes.")
                    .font(Brand.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.muted)
                    .frame(maxWidth: 360)
                VStack(spacing: 8) {
                    ProgressView(value: model.modelReady ? 1 : model.downloadProgress)
                        .tint(Brand.coral)
                        .frame(maxWidth: 300)
                    Text(model.modelReady ? "Ready" : "\(Int(model.downloadProgress * 100))%")
                        .font(Brand.caption.monospacedDigit())
                        .foregroundStyle(Brand.muted)
                }
                Button("Continue") { model.step = .trigger }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.modelReady)
                    .opacity(model.modelReady ? 1 : 0.45)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Resume mid-wizard or if welcome didn't start the load
            model.startModelIfNeeded()
        }
    }

    private var done: some View {
        stepShell(
            icon: "checkmark.seal.fill",
            title: "You're all set",
            body: "Hold \(Self.hotkeyLabel), speak, then release — words paste where the cursor is. OpenWispr lives in the menu bar (not the Dock).",
            primary: ("Start using OpenWispr", { model.onFinish() })
        ) {
            Text("Change the hotkey or model anytime in Settings")
                .font(Brand.caption)
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
    }

    private static var hotkeyLabel: String { AppController.hotkeyHint }

    // MARK: - Shared chrome

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Brand.caption.weight(.medium))
            .foregroundStyle(Brand.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Brand.surface)
                    .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
            )
    }

    private func iconBadge(_ systemName: String, tint: Color = Brand.coral) -> some View {
        Image(systemName: systemName)
            .font(Brand.display)
            .foregroundStyle(tint)
            .frame(width: 64, height: 64)
            .background(
                Circle()
                    .fill(Brand.surface)
                    .overlay(Circle().stroke(Brand.line, lineWidth: 1))
            )
    }

    @ViewBuilder
    private func stepShell(
        icon: String,
        title: String,
        body: String,
        primary: (String, () -> Void),
        secondary: (String, () -> Void)? = nil,
        @ViewBuilder extra: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            iconBadge(icon)
            Text(title)
                .font(Brand.title)
                .foregroundStyle(Brand.text)
                .multilineTextAlignment(.center)
            Text(body)
                .font(Brand.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.muted)
                .frame(maxWidth: 380)
            extra()
            Spacer(minLength: 8)
            Button(primary.0, action: primary.1)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            if let secondary {
                Button(secondary.0, action: secondary.1)
                    .buttonStyle(.plain)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Primary CTA style

private struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = Brand.coral
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.heading)
            .foregroundStyle(Brand.onAccent)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Brand.rSm, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.85 : 1))
            )
    }
}

// MARK: - Permissions + live mic (merged mic grant + VU + AX + optional meetings)

private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel
    let hotkeyMode: String
    let onContinue: () -> Void
    @StateObject private var meter = MicLevelMeter()

    private var canContinue: Bool {
        model.micGranted && (model.axGranted || hotkeyMode != "fn")
    }

    var body: some View {
        VStack(spacing: 16) {
            iconBadge("lock.shield.fill")
            Text("Permissions")
                .font(Brand.title)
                .foregroundStyle(Brand.text)
            Text("Two grants so OpenWispr can hear you and paste at the cursor. Audio never leaves this Mac.")
                .font(Brand.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.muted)
                .frame(maxWidth: 380)

            // Mic row + VU
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    statusDot(model.micGranted)
                    Text("Microphone")
                        .font(Brand.heading)
                        .foregroundStyle(Brand.text)
                    Spacer()
                    if model.micGranted {
                        Text("Granted")
                            .font(Brand.caption)
                            .foregroundStyle(Brand.ok)
                    } else if model.micDenied {
                        Button("Open Settings") { model.openMicSettings() }
                            .font(Brand.caption.weight(.medium))
                    } else {
                        Button("Allow") { model.requestMic() }
                            .font(Brand.caption.weight(.semibold))
                            .foregroundStyle(Brand.coral)
                    }
                }
                if model.micGranted {
                    HStack(spacing: 4) {
                        ForEach(0..<16, id: \.self) { i in
                            Capsule()
                                .fill(Double(i) / 16 < meter.level ? Brand.coral : Brand.line)
                                .frame(width: 8, height: 28)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .animation(.easeOut(duration: 0.08), value: meter.level)
                    Text("Speak — the bars should move.")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.muted)
                } else if model.micDenied {
                    Text("Denied. System Settings → Privacy & Security → Microphone → OpenWispr.")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.warn)
                }
            }
            .padding(Brand.s12)
            .background(card)

            // Accessibility row
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    statusDot(model.axGranted)
                    Text("Accessibility")
                        .font(Brand.heading)
                        .foregroundStyle(Brand.text)
                    Spacer()
                    if model.axGranted {
                        Text("Granted")
                            .font(Brand.caption)
                            .foregroundStyle(Brand.ok)
                    } else {
                        Button("Open Settings") {
                            model.requestAccessibility()
                        }
                        .font(Brand.caption.weight(.medium))
                    }
                }
                Text(model.axGranted
                      ? "fn trigger and auto-paste are enabled."
                      : "Needed for the fn key and to paste at the cursor.")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.muted)
                if !model.axGranted {
                    Button("I've enabled it — re-check") {
                        model.refreshAccessibility()
                    }
                    .font(Brand.caption.weight(.medium))
                    .foregroundStyle(Brand.coral)
                }
            }
            .padding(Brand.s12)
            .background(card)

            // Optional meetings
            HStack(spacing: 8) {
                Image(systemName: (model.screenRecGranted || model.screenRecPrompted)
                      ? "checkmark.circle.fill" : "rectangle.inset.filled.badge.record")
                    .foregroundStyle((model.screenRecGranted || model.screenRecPrompted) ? Brand.ok : Brand.muted)
                if model.screenRecGranted || model.screenRecPrompted {
                    Text(model.screenRecGranted ? "Meeting capture enabled" : "Meeting capture requested (applies next launch)")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.muted)
                } else {
                    Button("Also enable meeting capture (optional)") {
                        model.requestScreenRecording()
                    }
                    .font(Brand.caption)
                    .foregroundStyle(Brand.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            Spacer(minLength: 0)

            Button("Continue") { onContinue() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.45)
            if !model.axGranted && hotkeyMode != "fn" {
                Button("Skip Accessibility for now") { onContinue() }
                    .buttonStyle(.plain)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.refreshAccessibility()
            if model.micGranted { meter.start() }
        }
        .onChange(of: model.micGranted) { _, granted in
            if granted { meter.start() } else { meter.stop() }
        }
        .onDisappear { meter.stop() }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: Brand.rMd, style: .continuous)
            .fill(Brand.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Brand.rMd, style: .continuous)
                    .stroke(Brand.line, lineWidth: 1)
            )
    }

    private func statusDot(_ ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "circle")
            .font(Brand.heading)
            .foregroundStyle(ok ? Brand.ok : Brand.line)
    }

    private func iconBadge(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(Brand.display)
            .foregroundStyle(Brand.coral)
            .frame(width: 64, height: 64)
            .background(
                Circle()
                    .fill(Brand.surface)
                    .overlay(Circle().stroke(Brand.line, lineWidth: 1))
            )
    }
}

// MARK: - Trigger pick + press-test + toggles (merged setup + hotkey test)

private struct TriggerStep: View {
    @Binding var hotkeyMode: String
    @Binding var launchAtLogin: Bool
    @Binding var loginItemFailed: Bool
    let onContinue: () -> Void

    @State private var monitor: ModifierKeyMonitor?
    @State private var lit = false
    @State private var everFired = false

    private var isModifier: Bool { hotkeyMode != "custom" }
    private var label: String { Triggers.trigger(for: hotkeyMode).label }

    var body: some View {
        VStack(spacing: 16) {
            iconBadge("keyboard")
            Text("Your dictation key")
                .font(Brand.title)
                .foregroundStyle(Brand.text)
            Text(isModifier
                  ? "Hold \(label) to talk. Press it once so we know it works."
                  : "Pick a custom shortcut, then continue. You’ll test it after setup.")
                .font(Brand.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.muted)
                .frame(maxWidth: 380)

            Picker("Trigger", selection: $hotkeyMode) {
                ForEach(Triggers.list, id: \.id) { t in
                    Text(t.label).tag(t.id)
                }
                Text("Custom shortcut").tag("custom")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            .onChange(of: hotkeyMode) { _, _ in
                NotificationCenter.default.post(name: .whisprHotkeyModeChanged, object: nil)
                everFired = false
                lit = false
                attach()
            }

            if isModifier {
                Text(label)
                    .font(Brand.mono(22).weight(.semibold))
                    .frame(width: 140, height: 80)
                    .background(
                        RoundedRectangle(cornerRadius: Brand.rLg, style: .continuous)
                            .fill(lit ? Brand.coral.opacity(0.22) : Brand.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.rLg, style: .continuous)
                            .stroke(lit ? Brand.coral : Brand.line, lineWidth: lit ? 2 : 1)
                    )
                    .animation(.easeOut(duration: 0.1), value: lit)
                Text(everFired ? "Detected. Your key works." : "Nothing yet? Check Accessibility on the previous step.")
                    .font(Brand.caption)
                    .foregroundStyle(everFired ? Brand.ok : Brand.muted)
            } else {
                KeyboardShortcuts.Recorder("Shortcut:", name: .dictate)
                    .frame(maxWidth: 260)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Start OpenWispr at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if LoginItem.set(on) { loginItemFailed = false }
                        else { launchAtLogin = false; loginItemFailed = true }
                    }
                if loginItemFailed {
                    Text("Could not set launch at login. Move OpenWispr to Applications first.")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.warn)
                } else if hotkeyMode == "fn" {
                    Text("Tip: set System Settings → Keyboard → “Press globe key to” to Do Nothing.")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.muted)
                }
            }
            .font(Brand.body)
            .frame(maxWidth: 340)
            .padding(.top, 4)

            Spacer(minLength: 0)

            Button("Continue") { onContinue() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                // Prefer a successful press-test for modifiers; don't hard-block power users
                .opacity(isModifier && !everFired ? 0.7 : 1)
            if isModifier && !everFired {
                Text("Hold the key once for a confident setup — or continue anyway.")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            attach()
        }
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

    private func iconBadge(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(Brand.display)
            .foregroundStyle(Brand.coral)
            .frame(width: 64, height: 64)
            .background(
                Circle()
                    .fill(Brand.surface)
                    .overlay(Circle().stroke(Brand.line, lineWidth: 1))
            )
    }
}

// MARK: - Practice with the real gesture (hold the key → speak → release)

private struct PracticeStep: View {
    @ObservedObject var model: OnboardingModel
    let hotkeyMode: String

    @State private var monitor: ModifierKeyMonitor?

    private var isModifier: Bool { hotkeyMode != "custom" }
    private var label: String { Triggers.trigger(for: hotkeyMode).label }
    private var isRecording: Bool { if case .recording = model.practice { true } else { false } }

    var body: some View {
        VStack(spacing: 20) {
            iconBadge("waveform.and.mic")
            Text("Try it for real").font(Brand.title).foregroundStyle(Brand.text)
            Text(isModifier
                  ? "Hold \(label), say “OpenWispr types what I say”, then release."
                  : "Press the button, say something like “OpenWispr types what I say”, then stop.")
                .font(Brand.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.muted)
                .frame(maxWidth: 360)

            switch model.practice {
            case .idle, .recording:
                if isModifier {
                    // Same key-cap as the trigger step — lit while it's actually recording.
                    Text(label)
                        .font(Brand.mono(22).weight(.semibold))
                        .frame(width: 140, height: 80)
                        .background(
                            RoundedRectangle(cornerRadius: Brand.rLg, style: .continuous)
                                .fill(isRecording ? Brand.coral.opacity(0.22) : Brand.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Brand.rLg, style: .continuous)
                                .stroke(isRecording ? Brand.coral : Brand.line, lineWidth: isRecording ? 2 : 1)
                        )
                        .animation(.easeOut(duration: 0.1), value: isRecording)
                    Text(isRecording ? "Listening — release to finish." : "Holding the key starts the mic.")
                        .font(Brand.caption)
                        .foregroundStyle(isRecording ? Brand.coral : Brand.muted)
                } else if isRecording {
                    Button("Stop") { model.onPracticeStop() }
                        .buttonStyle(PrimaryButtonStyle(fill: Brand.danger.opacity(0.9)))
                        .keyboardShortcut(.defaultAction)
                    Text("Listening…")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.ok)
                } else {
                    Button("Start recording") { model.onPracticeStart() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            case .transcribing:
                ProgressView("Transcribing…")
                    .tint(Brand.coral)
            case .result(let text):
                VStack(alignment: .leading, spacing: 10) {
                    Text("You said")
                        .font(Brand.caption.weight(.semibold))
                        .foregroundStyle(Brand.muted)
                    Text(text.isEmpty ? "(heard nothing — try again)" : "“\(text)”")
                        .font(Brand.serif(15).italic())
                        .foregroundStyle(text.isEmpty ? Brand.muted : Brand.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .frame(maxWidth: 380)
                .background(
                    RoundedRectangle(cornerRadius: Brand.rMd, style: .continuous)
                        .fill(Brand.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Brand.rMd, style: .continuous)
                                .stroke(Brand.line, lineWidth: 1)
                        )
                )
                if wordCount(text) > 0 {
                    Text("\(wordCount(text)) words — typing that takes ~\(Int((Double(wordCount(text)) * 1.5).rounded()))s at 40 wpm.")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.muted)
                }
                HStack(spacing: 14) {
                    Button("Try again") { model.practice = .idle }
                        .buttonStyle(.plain)
                        .font(Brand.body.weight(.medium))
                        .foregroundStyle(Brand.muted)
                    Button("Continue") { model.step = .done }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }

            if case .result = model.practice {} else {
                Button("Skip") { model.step = .done }
                    .buttonStyle(.plain)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.muted)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { attach() }
        .onDisappear {
            monitor = nil
            if isRecording { model.onPracticeStop() }
        }
    }

    /// Hold-to-talk: key-down starts the practice mic, key-up stops it — the real dictation gesture.
    private func attach() {
        guard isModifier else { monitor = nil; return }
        monitor = ModifierKeyMonitor(
            trigger: Triggers.trigger(for: hotkeyMode),
            onKeyDown: {
                if case .idle = model.practice { model.onPracticeStart() }
            },
            onKeyUp: {
                if case .recording = model.practice { model.onPracticeStop() }
            }
        )
    }

    private func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: \.isWhitespace).count
    }

    private func iconBadge(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(Brand.display)
            .foregroundStyle(Brand.coral)
            .frame(width: 64, height: 64)
            .background(
                Circle()
                    .fill(Brand.surface)
                    .overlay(Circle().stroke(Brand.line, lineWidth: 1))
            )
    }
}
