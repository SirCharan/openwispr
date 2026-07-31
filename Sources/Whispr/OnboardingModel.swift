import SwiftUI
import AVFoundation
import AppKit

/// Drives the first-run wizard: permission grants + model-download progress.
@MainActor
final class OnboardingModel: ObservableObject {
    enum PracticeState { case idle, recording, transcribing, result(String) }

    @Published var step = 0
    @Published var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var axGranted = Permissions.hasAccessibility
    @Published var screenRecGranted = CGPreflightScreenCaptureAccess()
    @Published var downloadProgress = 0.0
    @Published var modelReady = false
    @Published var modelError: String?
    @Published var screenRecPrompted = false
    @Published var practice: PracticeState = .idle

    var micDenied: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .denied }

    /// Running from outside /Applications (Downloads, a mounted DMG…) → offer to move.
    var needsMove: Bool { !Bundle.main.bundlePath.hasPrefix("/Applications") }

    /// Set by AppController: start the model download/load, routing progress back here.
    var onStartModel: () -> Void = {}
    /// Set by AppController: copy the app to /Applications and relaunch from there.
    var onMoveToApplications: () -> Void = {}
    /// Set by AppController: start/stop a practice recording (result lands in `practice`).
    var onPracticeStart: () -> Void = {}
    var onPracticeStop: () -> Void = {}
    /// Set by AppController: persist onboarded, attach hotkeys, close the window.
    var onFinish: () -> Void = {}

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess() // prompts + adds Whispr to the pane; grant needs relaunch to take effect
        screenRecGranted = CGPreflightScreenCaptureAccess()
        screenRecPrompted = true // preflight stays false until relaunch — treat the prompt as progress
    }

    func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

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

    /// Personalize screen: voice ≈ 4× typing, so ~3/4 of daily typing time is saved.
    static func hoursSavedPerWeek(typingHoursPerDay: Double) -> Double {
        typingHoursPerDay * 0.75 * 7
    }

    /// Driven by the `hours_saved_per_week` table in `core/fixtures/stats.json`, so the number
    /// shown in onboarding is the same on macOS and Windows.
    static func selfTest() {
        let f = Fixtures.load(Stats.FixtureFile.self, "stats.json")
        Fixtures.expect(!f.hoursSavedPerWeek.isEmpty, "stats.json has no hoursSavedPerWeek cases")
        for c in f.hoursSavedPerWeek {
            Fixtures.expectClose(hoursSavedPerWeek(typingHoursPerDay: c.typingHoursPerDay), c.expected,
                                 "hoursSavedPerWeek(\(c.typingHoursPerDay))")
        }
        print("OnboardingModel.selfTest PASS (\(f.hoursSavedPerWeek.count) cases)")
    }
}
