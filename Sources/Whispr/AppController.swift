import AppKit

/// Central wiring object: owns the menu bar, model, and transcriber, and runs the boot sequence.
/// Recording + hotkey + paste flow is attached in later milestones.
@MainActor
final class AppController {
    private lazy var menuBar = MenuBarController(
        onSettings: { [weak self] in self?.showSettings() },
        onMeeting: { [weak self] in self?.showMeeting() },
        onImport: { [weak self] in self?.showImport() }
    )
    private let meetingWindow = MeetingWindowController()
    private let importWindow = FileImportWindowController()
    private let corrections = CorrectionsWatcher()
    private var previewTimer: Timer?
    private var previewBusy = false
    private let modelManager = ModelManager()
    private let transcriber = Transcriber()
    private let recorder = AudioRecorder()
    private var hotkeys: HotkeyManager?
    private let indicator = RecordingIndicator()
    private let settingsWindow = SettingsWindowController()
    private var onboarding: OnboardingWindowController?

    func start() {
        if Settings.onboarded {
            Task { await bootModel() }
        } else {
            showOnboarding()
        }
    }

    private func bootModel() async {
        await loadSelectedModel()
        attachHotkeys()
        if Settings.autoPaste && !Permissions.hasAccessibility {
            Permissions.requestAccessibility() // one-time prompt so auto-paste works
        }
    }

    // MARK: - First-run onboarding

    private func showOnboarding() {
        setStatus("setup…")
        let vm = OnboardingModel()
        vm.onStartModel = { [weak self, weak vm] in
            Task { await self?.loadModelForOnboarding(vm) }
        }
        vm.onPracticeStart = { [weak self, weak vm] in
            guard let self, let vm else { return }
            do {
                try self.recorder.start()
                vm.practice = .recording
            } catch {
                vm.practice = .result("(microphone error — check permission)")
            }
        }
        vm.onPracticeStop = { [weak self, weak vm] in
            guard let self, let vm else { return }
            let samples = self.recorder.stop()
            vm.practice = .transcribing
            Task {
                do {
                    let raw = try await self.transcriber.transcribe(samples, language: Settings.languageCode)
                    vm.practice = .result(TextProcessor.process(raw, options: Settings.textOptions))
                } catch {
                    vm.practice = .result("(transcription failed — you can still continue)")
                }
            }
        }
        vm.onFinish = { [weak self] in
            Settings.onboarded = true
            self?.attachHotkeys()
            self?.setStatus("ready — hold ⌘⇧D to dictate")
            self?.onboarding?.close()
            self?.onboarding = nil
        }
        onboarding = OnboardingWindowController(model: vm)
        onboarding?.show()
    }

    private func loadModelForOnboarding(_ vm: OnboardingModel?) async {
        guard let vm else { return }
        let model = modelManager.selectedModel
        do {
            let folder = try await modelManager.ensureDownloaded(model) { frac in vm.downloadProgress = frac }
            try await transcriber.load(model: model, folder: folder)
            vm.modelReady = true
        } catch {
            NSLog("[Whispr] onboarding model load failed: \(error)")
        }
    }

    /// Download (if needed) and load the currently-selected model. Reused for live model switches.
    // ponytail: no guard against overlapping reloads — worst case two loads race; last write wins. Add a flag if it matters.
    private func loadSelectedModel() async {
        let model = modelManager.selectedModel
        do {
            setStatus("downloading \(model)…")
            let folder = try await modelManager.ensureDownloaded(model) { [weak self] frac in
                self?.setStatus("downloading \(Int(frac * 100))%")
            }
            setStatus("loading model…")
            try await transcriber.load(model: model, folder: folder)
            setStatus("ready — hold ⌘⇧D to dictate")
        } catch {
            setStatus("model error")
            NSLog("[Whispr] model load failed: \(error)")
        }
    }

    private func showMeeting() {
        guard transcriber.isReady else { setStatus("model still loading…"); return }
        meetingWindow.show(transcriber: transcriber)
    }

    private func showImport() {
        guard transcriber.isReady else { setStatus("model still loading…"); return }
        importWindow.show(transcriber: transcriber)
    }

    private func showSettings() {
        settingsWindow.show(
            currentModel: modelManager.selectedModel,
            models: ModelManager.available,
            onReloadModel: { [weak self] name in
                guard let self, name != self.modelManager.selectedModel else { return }
                self.modelManager.selectedModel = name
                Task { await self.loadSelectedModel() }
            }
        )
    }

    private func attachHotkeys() {
        hotkeys = HotkeyManager(
            onKeyDown: { [weak self] in self?.handleKeyDown() },
            onKeyUp: { [weak self] in self?.handleKeyUp() }
        )
    }

    /// Hold-to-talk: key-down starts. Hands-free: key-down toggles start/stop.
    private func handleKeyDown() {
        if Settings.handsFree {
            if recorder.isRecording { stopDictation() } else { startDictation() }
        } else {
            startDictation()
        }
    }

    /// Hold-to-talk: key-up stops. Hands-free ignores key-up.
    private func handleKeyUp() {
        if !Settings.handsFree { stopDictation() }
    }

    // MARK: - Dictation flow (hold hotkey → record → release → transcribe → paste)

    private func startDictation() {
        guard transcriber.isReady, !recorder.isRecording else { return }
        if let front = AppMonitor.frontmostBundleID(), Settings.disabledApps.contains(front) {
            setStatus("disabled for \(AppMonitor.name(for: front))")
            return
        }
        do {
            try recorder.start()
            menuBar.setRecording(true)
            indicator.show(
                onCancel: { [weak self] in self?.cancelDictation() },
                onStop: { [weak self] in self?.stopDictation() }
            )
            setStatus("listening…")
            startPreviewLoop()
        } catch {
            setStatus("mic error")
            NSLog("[Whispr] mic start failed: \(error)")
        }
    }

    /// Eager preview: every 2s re-transcribe the last ~10s of buffer (greedy) and show
    /// the tail in the pill. ponytail: re-transcribe loop, not a realtime model — skip
    /// ticks while the previous one runs; upgrade path = dedicated streaming backend.
    private func startPreviewLoop() {
        previewTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.previewTick() }
        }
    }

    private func stopPreviewLoop() {
        previewTimer?.invalidate(); previewTimer = nil
        previewBusy = false
    }

    private func previewTick() {
        guard recorder.isRecording, !previewBusy else { return }
        let samples = recorder.snapshot(last: 10)
        guard samples.count > 16000 else { return } // need >1s
        previewBusy = true
        Task {
            defer { previewBusy = false }
            guard let raw = try? await transcriber.transcribe(samples, language: Settings.languageCode),
                  recorder.isRecording else { return }
            let words = raw.split(separator: " ").suffix(8).joined(separator: " ")
            indicator.model.preview = words
        }
    }

    /// Discard the current recording without transcribing.
    private func cancelDictation() {
        guard recorder.isRecording else { return }
        stopPreviewLoop()
        _ = recorder.stop()
        menuBar.setRecording(false)
        indicator.hide()
        setStatus("ready — hold ⌘⇧D to dictate")
    }

    private func stopDictation() {
        guard recorder.isRecording else { return }
        stopPreviewLoop()
        let samples = recorder.stop()
        menuBar.setRecording(false)
        indicator.hide()
        setStatus("transcribing…")
        Task {
            do {
                let raw = try await transcriber.transcribe(samples, language: Settings.languageCode)
                let corrected = DictionaryStore.apply(raw, DictionaryStore.load())
                let cleaned = TextProcessor.process(corrected, options: Settings.textOptions)
                var text = SnippetStore.apply(cleaned, SnippetStore.load())
                text = await Self.rewriteIfEnabled(text) { [weak self] in self?.setStatus($0) }
                if text.isEmpty {
                    setStatus("ready (no speech)")
                } else {
                    Paster.deliver(text, autoPaste: Settings.autoPaste)
                    HistoryStore.add(text)
                    corrections.notePaste(text)
                    setStatus("ready")
                }
            } catch {
                setStatus("transcribe error")
                NSLog("[Whispr] transcribe failed: \(error)")
            }
        }
    }

    private func setStatus(_ text: String) {
        menuBar.setStatus(text)
        NSLog("[Whispr] status: \(text)")
    }

    /// Apply the configured AI rewrite style; on any failure return the original text (paste never blocks on AI errors).
    static func rewriteIfEnabled(_ text: String, status: @escaping (String) -> Void) async -> String {
        let style = Settings.rewriteStyle
        guard style != "off", !text.isEmpty else { return text }
        guard await LLMClient.available() else { return text }
        status("rewriting (\(style))…")
        let prompts = [
            "clean": "Fix grammar and punctuation. Keep the meaning, wording, and tone. Reply with only the corrected text.",
            "formal": "Rewrite in a professional, formal tone. Keep the meaning. Reply with only the rewritten text.",
            "concise": "Rewrite as concisely as possible without losing meaning. Reply with only the rewritten text.",
        ]
        guard let system = prompts[style] else { return text }
        do {
            let out = try await LLMClient.complete(system: system, user: text)
            return out.isEmpty ? text : out
        } catch {
            NSLog("[Whispr] rewrite failed, pasting original: \(error)")
            return text
        }
    }
}
