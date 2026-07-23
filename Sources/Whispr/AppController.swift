import AppKit

/// Central wiring object: owns the menu bar, model, and transcriber, and runs the boot sequence.
/// Recording + hotkey + paste flow is attached in later milestones.
@MainActor
final class AppController {
    private let menuBar = MenuBarController()
    private let modelManager = ModelManager()
    private let transcriber = Transcriber()
    private let recorder = AudioRecorder()
    private var hotkeys: HotkeyManager?

    func start() {
        Task { await bootModel() }
    }

    /// Download (if needed) and load the selected model, surfacing state in the menu bar.
    private func bootModel() async {
        let model = modelManager.selectedModel
        do {
            setStatus("downloading \(model)…")
            let folder = try await modelManager.ensureDownloaded(model) { [weak self] frac in
                self?.setStatus("downloading \(Int(frac * 100))%")
            }
            setStatus("loading model…")
            try await transcriber.load(model: model, folder: folder)
            setStatus("ready — hold ⌘⇧D to dictate")
            attachHotkeys()
            if Settings.autoPaste && !Permissions.hasAccessibility {
                Permissions.requestAccessibility() // one-time prompt so auto-paste works
            }
        } catch {
            setStatus("model error")
            NSLog("[Whispr] model boot failed: \(error)")
        }
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
