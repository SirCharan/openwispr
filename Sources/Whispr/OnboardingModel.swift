import SwiftUI
import AVFoundation

/// Drives the first-run wizard: permission grants + model-download progress.
@MainActor
final class OnboardingModel: ObservableObject {
    enum PracticeState { case idle, recording, transcribing, result(String) }

    @Published var step = 0
    @Published var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var axGranted = Permissions.hasAccessibility
    @Published var downloadProgress = 0.0
    @Published var modelReady = false
    @Published var practice: PracticeState = .idle

    /// Set by AppController: start the model download/load, routing progress back here.
    var onStartModel: () -> Void = {}
    /// Set by AppController: start/stop a practice recording (result lands in `practice`).
    var onPracticeStart: () -> Void = {}
    var onPracticeStop: () -> Void = {}
    /// Set by AppController: persist onboarded, attach hotkeys, close the window.
    var onFinish: () -> Void = {}

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in self.micGranted = granted }
        }
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        refreshAccessibility()
    }

    /// AX grant happens in System Settings (async) — call on appear / button tap to re-check.
    func refreshAccessibility() {
        axGranted = Permissions.hasAccessibility
    }
}
