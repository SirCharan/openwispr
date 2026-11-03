import AppKit
import ScreenCaptureKit

/// Watches for a Zoom / Meet / Teams meeting window and offers to record it. Never auto-stops.
/// Per-app choice lives in defaults as `meetingAutoStart.<id>`: ask | always | never.
@MainActor
final class MeetingWindowDetector {
    struct Meeting: Equatable {
        let id: String    // "us.zoom.xos", "meet.google.com", "com.microsoft.teams"
        let name: String  // "Zoom", "Google Meet", "Teams"
    }

    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
    ]

    /// Pure: first meeting signal among (owning bundle id, window title) pairs.
    nonisolated static func classify(_ windows: [(bundle: String, title: String)], cptHostRunning: Bool) -> Meeting? {
        for w in windows {
            if w.bundle == "us.zoom.xos", w.title.contains("Zoom Meeting") { return Meeting(id: w.bundle, name: "Zoom") }
            if browsers.contains(w.bundle), w.title.hasPrefix("Meet –") || w.title.contains("Google Meet") {
                return Meeting(id: "meet.google.com", name: "Google Meet")
            }
            if w.bundle.hasPrefix("com.microsoft.teams"), w.title.contains("Meeting") {
                return Meeting(id: "com.microsoft.teams", name: "Teams")
            }
        }
        return cptHostRunning ? Meeting(id: "us.zoom.xos", name: "Zoom") : nil
    }

    /// The meeting currently confirmed on screen (read by ZoomRosterReader).
    private(set) var current: Meeting?

    private let isRecording: () -> Bool
    private let startRecording: () -> Void
    private let prompt: (String, [(String, () -> Void)]) -> Void
    private var timer: Timer?
    private var candidate: Meeting?
    private var handled: String?          // id already prompted for during this appearance
    private var goneSince: Date?
    private var seenWhileRecording = false
    private var stopAsked = false

    init(isRecording: @escaping () -> Bool, startRecording: @escaping () -> Void,
         prompt: @escaping (String, [(String, () -> Void)]) -> Void) {
        self.isRecording = isRecording
        self.startRecording = startRecording
        self.prompt = prompt
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    private func sample() async -> Meeting? {
        // Never touch SCShareableContent without permission: it would pop the Screen Recording
        // prompt for dictation-only users. CptHost (Zoom) needs no permission, so it still runs.
        var wins: [(bundle: String, title: String)] = []
        if CGPreflightScreenCaptureAccess(),
           let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) {
            wins = content.windows.compactMap { w -> (bundle: String, title: String)? in
                guard let b = w.owningApplication?.bundleIdentifier, let t = w.title else { return nil }
                return (b, t)
            }
        }
        let cpt = NSWorkspace.shared.runningApplications.contains { $0.executableURL?.lastPathComponent == "CptHost" }
        return Self.classify(wins, cptHostRunning: cpt)
    }

    private func tick() async {
        guard Settings.detectMeetings else { current = nil; return }
        let first = await sample()
        if isRecording() {
            trackRecording(first)
            return
        }
        seenWhileRecording = false; stopAsked = false; goneSince = nil
        guard let m = first else { current = nil; candidate = nil; handled = nil; return }
        guard m != candidate else { return }
        candidate = m
        try? await Task.sleep(for: .seconds(2.5)) // the signal must hold
        guard await sample() == m, !isRecording(), handled != m.id else { return }
        current = m
        handled = m.id
        offer(m)
    }

    /// The Meet extension reported the call UI: same Start / Not now / Always prompt.
    func extensionJoined() {
        guard Settings.detectMeetings, !isRecording(), handled != "meet-extension" else { return }
        handled = "meet-extension"
        offer(Meeting(id: "meet-extension", name: "Google Meet"))
    }

    /// The Meet extension reported the leave page.
    func extensionLeft() {
        handled = nil
        guard isRecording(), !stopAsked else { return }
        stopAsked = true
        prompt("Meeting window closed. Stop recording?", [
            ("Stop", { NotificationCenter.default.post(name: .whisprStopMeeting, object: nil) }),
            ("Keep recording", {}),
        ])
    }

    private func offer(_ m: Meeting) {
        switch UserDefaults.standard.string(forKey: "meetingAutoStart.\(m.id)") ?? "ask" {
        case "always": startRecording()
        case "never": break
        default:
            prompt("Meeting detected in \(m.name). Start recording?", [
                ("Start", { [weak self] in self?.startRecording() }),
                ("Not now", {}),
                ("Always for \(m.name)", { [weak self] in
                    UserDefaults.standard.set("always", forKey: "meetingAutoStart.\(m.id)")
                    self?.startRecording()
                }),
            ])
        }
    }

    /// During a recording: offer (never force) a stop once the meeting window has been gone for 5 s.
    private func trackRecording(_ m: Meeting?) {
        if let m { current = m; seenWhileRecording = true; goneSince = nil; return }
        guard seenWhileRecording, !stopAsked else { return }
        let since = goneSince ?? Date()
        goneSince = since
        guard Date().timeIntervalSince(since) >= 5 else { return }
        stopAsked = true
        prompt("Meeting window closed. Stop recording?", [
            ("Stop", { NotificationCenter.default.post(name: .whisprStopMeeting, object: nil) }),
            ("Keep recording", {}),
        ])
    }

    static func selfTest() {
        let z = classify([("us.zoom.xos", "Zoom Meeting")], cptHostRunning: false)
        precondition(z == Meeting(id: "us.zoom.xos", name: "Zoom"), "zoom window")
        precondition(classify([("us.zoom.xos", "Zoom Workplace")], cptHostRunning: false) == nil, "zoom home is not a meeting")
        precondition(classify([("us.zoom.xos", "Zoom Workplace")], cptHostRunning: true)?.name == "Zoom", "CptHost fallback")
        precondition(classify([("com.google.Chrome", "Meet – abc-defg-hij")], cptHostRunning: false)?.id == "meet.google.com", "meet prefix")
        precondition(classify([("com.google.Chrome", "Standup - Google Meet")], cptHostRunning: false) != nil, "meet contains")
        precondition(classify([("com.google.Chrome", "Meet – x")].map { ("com.example.app", $0.1) }, cptHostRunning: false) == nil, "non-browser")
        precondition(classify([("com.microsoft.teams2", "Sync | Meeting")], cptHostRunning: false)?.name == "Teams", "teams")
        precondition(classify([("com.microsoft.teams2", "Chat")], cptHostRunning: false) == nil, "teams chat")
        print("MeetingWindowDetector.selfTest PASS")
    }
}

extension Notification.Name {
    static let whisprStopMeeting = Notification.Name("whisprStopMeeting")
    static let whisprMeetExtensionChanged = Notification.Name("whisprMeetExtensionChanged")
}
