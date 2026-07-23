import AppKit

/// Central wiring object: owns the menu bar, model, and transcriber, and runs the boot sequence.
/// Recording + hotkey + paste flow is attached in later milestones.
@MainActor
final class AppController {
    private lazy var menuBar = MenuBarController(onSettings: { [weak self] in self?.showSettings() })
    private let modelManager = ModelManager()
    private let transcriber = Transcriber()
    private let recorder = AudioRecorder()
    private var hotkeys: HotkeyManager?
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
        do {
            try recorder.start()
            menuBar.setRecording(true)
            setStatus("listening…")
        } catch {
            setStatus("mic error")
            NSLog("[Whispr] mic start failed: \(error)")
        }
    }

    private func stopDictation() {
        guard recorder.isRecording else { return }
        let samples = recorder.stop()
        menuBar.setRecording(false)
        setStatus("transcribing…")
        Task {
            do {
                let raw = try await transcriber.transcribe(samples)
                let corrected = DictionaryStore.apply(raw, DictionaryStore.load())
                let cleaned = TextProcessor.process(corrected, options: Settings.textOptions)
                let text = SnippetStore.apply(cleaned, SnippetStore.load())
                if text.isEmpty {
                    setStatus("ready (no speech)")
                } else {
                    Paster.deliver(text, autoPaste: Settings.autoPaste)
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
}
