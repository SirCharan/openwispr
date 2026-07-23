import AppKit

/// Central wiring object: owns the menu bar, model, and transcriber, and runs the boot sequence.
/// Recording + hotkey + paste flow is attached in later milestones.
@MainActor
final class AppController {
    private let menuBar = MenuBarController()
    private let modelManager = ModelManager()
    private let transcriber = Transcriber()

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
            setStatus("ready")
        } catch {
            setStatus("model error")
            NSLog("[Whispr] model boot failed: \(error)")
        }
    }

    private func setStatus(_ text: String) {
        menuBar.setStatus(text)
        NSLog("[Whispr] status: \(text)")
    }
}
