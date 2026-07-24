import AppKit
import KeyboardShortcuts

/// Central wiring object: owns the menu bar, model, and transcriber, and runs the boot sequence.
/// Owns the dictation flow, onboarding, windows, and trigger monitors.
@MainActor
final class AppController {
    private lazy var menuBar = MenuBarController(
        onSettings: { [weak self] in self?.showSettings() },
        onMeeting: { [weak self] in self?.showMeeting() },
        onImport: { [weak self] in self?.showImport() },
        onOpen: { [weak self] in self?.showMainWindow() },
        onRetry: { [weak self] in self?.retryLastTranscription() }
    )
    let state = AppState()
    private let mainWindow = MainWindowController()
    private var fnMonitor: ModifierKeyMonitor?
    private lazy var meetingCtrl = MeetingController(transcriber: transcriber)
    private lazy var importModel = FileImportModel(transcriber: transcriber)
    private let corrections = CorrectionsWatcher()
    private var previewTimer: Timer?
    private var previewBusy = false
    private var previewTask: Task<Void, Never>?
    /// Mirrors the actor's readiness for synchronous UI guards.
    private var modelReady = false
    /// Samples of the last dictation whose transcription failed — recoverable via "Retry".
    private var failedSamples: [Float]?
    private let modelManager = ModelManager()
    private let transcriber = Transcriber()
    private let recorder = AudioRecorder()
    private var hotkeys: HotkeyManager?
    private let indicator = RecordingIndicator()
    private var onboarding: OnboardingWindowController?

    func start() {
        NotificationCenter.default.addObserver(forName: .whisprHotkeyModeChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.modelReady else { return }
                self.attachHotkeys()
                self.setStatus("ready — hold \(Self.hotkeyHint) to dictate")
            }
        }
        NotificationCenter.default.addObserver(forName: .whisprModelChanged, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let name = note.object as? String,
                      name != self.modelManager.selectedModel else { return }
                self.modelManager.selectedModel = name
                await self.loadSelectedModel()
            }
        }
        if Settings.onboarded {
            showMainWindow()
            Task { await bootModel() }
        } else {
            showOnboarding()
        }
    }

    func showMainWindow() {
        // wizard closed mid-way? "Open Whispr" resumes it instead of dead-ending
        guard Settings.onboarded else {
            if let onboarding { onboarding.show() } else { showOnboarding() }
            return
        }
        mainWindow.show(state: state, meetingController: meetingCtrl, importModel: importModel)
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
        vm.onMoveToApplications = { Self.moveToApplicationsAndRelaunch() }
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
            self?.setStatus("ready — hold \(Self.hotkeyHint) to dictate")
            self?.onboarding?.close()
            self?.onboarding = nil
            self?.showMainWindow()
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
            modelReady = true
            vm.modelReady = true
        } catch {
            vm.modelError = error.localizedDescription
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
            modelReady = false
            try await transcriber.load(model: model, folder: folder)
            modelReady = true
            setStatus("ready — hold \(Self.hotkeyHint) to dictate")
        } catch {
            setStatus("model error")
            NSLog("[Whispr] model load failed: \(error)")
        }
    }

    private func showMeeting() {
        state.pane = .meetings
        showMainWindow()
    }

    private func showImport() {
        state.pane = .importFile
        showMainWindow()
    }

    private func showSettings() {
        state.pane = .settings
        showMainWindow()
    }

    /// Attach the active trigger: fn monitor (default) or the custom shortcut. Re-call on mode change.
    func attachHotkeys() {
        if recorder.isRecording { stopDictation() } // never swap monitors mid-recording (drops the key-up)
        hotkeys = nil
        fnMonitor = nil
        if Self.effectiveMode == "custom" {
            hotkeys = HotkeyManager(
                onKeyDown: { [weak self] in self?.handleKeyDown() },
                onKeyUp: { [weak self] in self?.handleKeyUp() }
            )
        } else {
            fnMonitor = ModifierKeyMonitor(
                trigger: Triggers.trigger(for: Self.effectiveMode),
                onKeyDown: { [weak self] in self?.handleKeyDown() },
                onKeyUp: { [weak self] in self?.handleKeyUp() }
            )
        }
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
        guard modelReady, !recorder.isRecording else { return }
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
        previewTask?.cancel(); previewTask = nil
        previewBusy = false
    }

    private func previewTick() {
        guard recorder.isRecording, !previewBusy else { return }
        let samples = recorder.snapshot(last: 10)
        guard samples.count > 16000 else { return } // need >1s
        previewBusy = true
        previewTask = Task {
            defer { previewBusy = false }
            guard !Task.isCancelled,
                  let raw = try? await transcriber.transcribe(samples, language: Settings.languageCode),
                  !Task.isCancelled, recorder.isRecording else { return }
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
        setStatus("ready — hold \(Self.hotkeyHint) to dictate")
    }

    /// "custom" with nothing recorded falls back to fn — a trigger must always exist.
    static var effectiveMode: String {
        Settings.hotkeyMode == "custom" && KeyboardShortcuts.getShortcut(for: .dictate) == nil
            ? "fn" : Settings.hotkeyMode
    }

    static var hotkeyHint: String {
        effectiveMode == "custom"
            ? (KeyboardShortcuts.getShortcut(for: .dictate).map(String.init(describing:)) ?? "fn")
            : Triggers.trigger(for: effectiveMode).label
    }

    private func stopDictation() {
        guard recorder.isRecording else { return }
        stopPreviewLoop()
        let samples = recorder.stop()
        menuBar.setRecording(false)
        indicator.hide()
        setStatus("transcribing…")
        transcribeAndDeliver(samples)
    }

    /// Retry the last failed transcription (menu item).
    func retryLastTranscription() {
        guard let samples = failedSamples else { setStatus("nothing to retry"); return }
        failedSamples = nil
        setStatus("retrying…")
        transcribeAndDeliver(samples)
    }

    private func transcribeAndDeliver(_ samples: [Float]) {
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
                    HistoryStore.add(text, seconds: Double(samples.count) / 16000)
                    corrections.notePaste(text)
                    if Settings.autoPaste && !Permissions.hasAccessibility {
                        // grant missing (or invalidated by a rebuild) — say so instead of failing silently
                        setStatus("copied — grant Accessibility to auto-paste")
                        Permissions.requestAccessibility()
                    } else {
                        setStatus("ready")
                    }
                }
            } catch {
                failedSamples = samples // recoverable via Retry Last Transcription
                setStatus("transcribe error — Retry from the menu")
                NSLog("[Whispr] transcribe failed: \(error)")
            }
        }
    }

    private func setStatus(_ text: String) {
        menuBar.setStatus(text)
        state.status = text
        state.isRecording = recorder.isRecording
        NSLog("[Whispr] status: \(text)")
    }

    /// Copy the running bundle to /Applications and relaunch from there.
    /// ditto preserves the bundle + signature; TCC grants stick to the /Applications copy.
    static func moveToApplicationsAndRelaunch() {
        let src = Bundle.main.bundlePath
        let dst = "/Applications/Whispr.app"
        guard src != dst else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = [src, dst]
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                NSLog("[Whispr] move failed: ditto exit \(p.terminationStatus)"); return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: dst), configuration: config) { _, _ in
                Task { @MainActor in NSApp.terminate(nil) }
            }
        } catch {
            NSLog("[Whispr] move failed: \(error)")
        }
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
