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

    func start() {
        Task { await bootModel() }
    }

    private func bootModel() async {
        await loadSelectedModel()
        attachHotkeys()
        if Settings.autoPaste && !Permissions.hasAccessibility {
            Permissions.requestAccessibility() // one-time prompt so auto-paste works
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
            onStart: { [weak self] in self?.startDictation() },
            onStop: { [weak self] in self?.stopDictation() }
        )
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
                let text = try await transcriber.transcribe(samples)
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
