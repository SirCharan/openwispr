import AppKit
import SwiftUI

/// Headless UI renders for review: `Whispr --snap-panes <dir>`. Draws every Home pane, every
/// onboarding step and the floating views in light and dark into PNGs. Panes render the real
/// local data (history, stats, meetings) unless `--sample` swaps in `SampleData`; only the PNGs are written. The mic and screen capture
/// are never started (`isRendering` keeps the onboarding level meter off).
@MainActor
enum Snapshot {
    nonisolated(unsafe) static var isRendering = false
    nonisolated(unsafe) static var useSample = false

    static func run(dir: String, sample: Bool = false) {
        isRendering = true
        useSample = sample
        if sample { SampleData.install() }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let state = AppState()
        state.status = "ready · small.en"
        let transcriber = Transcriber()
        let meetings = MeetingController(transcriber: transcriber)
        let importModel = FileImportModel(transcriber: transcriber)
        let onboarding = OnboardingModel()

        for (tag, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: name)
            app.appearance = appearance

            for pane in HomePane.allCases {
                state.pane = pane
                let view = HomeView(state: state, meetingController: meetings, importModel: importModel)
                write(view, size: NSSize(width: 960, height: 672), appearance: appearance,
                      to: out.appendingPathComponent("\(tag)-\(slug(pane.rawValue)).png"))
            }

            RecoveryStore.sampleOverride = [
                FailedDictation(id: UUID(), startedAt: Date().addingTimeInterval(-600), seconds: 12, appBundleID: "com.apple.Notes",
                                message: "Transcription failed: model not loaded", partialText: nil)]
            state.pane = .dictations
            write(HomeView(state: state, meetingController: meetings, importModel: importModel), size: NSSize(width: 960, height: 672),
                  appearance: appearance, to: out.appendingPathComponent("\(tag)-dictations-failed.png"))
            RecoveryStore.sampleOverride = nil

            let setup = MeetingController(transcriber: transcriber)
            setup.previewSummaryState(lines: [MeetingLine(speaker: "You", text: "Let's ship Thursday.", start: 0, end: 4)], choice: SummaryChoice.none)
            write(MeetingView(controller: setup).background(Brand.bg), size: NSSize(width: 730, height: 560), appearance: appearance,
                  to: out.appendingPathComponent("\(tag)-meetings-setup.png"))

            write(MeetingView(controller: setup, lastSeenOverride: Date().addingTimeInterval(-120)).background(Brand.bg), size: NSSize(width: 730, height: 560), appearance: appearance,
                  to: out.appendingPathComponent("\(tag)-meetings-meetnames-connected.png"))

            for step in 0...OnboardingModel.Step.done.rawValue {
                onboarding.step = OnboardingModel.Step(rawValue: step) ?? .welcome
                write(OnboardingView(model: onboarding), size: NSSize(width: 520, height: 560), appearance: appearance,
                      to: out.appendingPathComponent("\(tag)-onboarding-\(step)-\(String(describing: onboarding.step)).png"))
            }

            let pill = PillModel()
            pill.preview = "so the plan for Thursday is to ship the new"
            write(RecordingPill(model: pill, onCancel: {}, onStop: {}), size: nil, appearance: appearance,
                  to: out.appendingPathComponent("\(tag)-float-pill.png"))
            let warn = PillModel()
            warn.warning = DictationHealth.silentMessage
            write(RecordingPill(model: warn, onCancel: {}, onStop: {}), size: nil, appearance: appearance,
                  to: out.appendingPathComponent("\(tag)-float-pill-warning.png"))
            write(IdlePillView(onTap: {}, onHide: {}), size: nil, appearance: appearance,
                  to: out.appendingPathComponent("\(tag)-float-idle.png"))
            write(ToastView(pairs: [(from: "stratsy", to: "Stratzy")], onAdd: {}, onClose: {}).frame(width: 340),
                  size: nil, appearance: appearance, to: out.appendingPathComponent("\(tag)-float-toast.png"))
            write(PromptView(message: "Meeting detected in Zoom. Start recording?",
                             labels: ["Start", "Not now", "Always"], onPick: { _ in }).frame(width: 340),
                  size: nil, appearance: appearance, to: out.appendingPathComponent("\(tag)-float-prompt.png"))
        }
        print("snap-panes: wrote to \(out.path)")
    }

    private static func slug(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "-") }

    /// Host in an off-screen window, let SwiftUI settle, render at 2x.
    private static func write<V: View>(_ view: V, size: NSSize?, appearance: NSAppearance?, to url: URL) {
        let content: AnyView = size == nil
            ? AnyView(view.padding(20).background(Brand.bg))
            : AnyView(view)
        let host = NSHostingView(rootView: content)
        let s = size ?? host.fittingSize
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: s), styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = appearance
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: s)
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderFrontRegardless()
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
        }
        let bounds = host.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        win.orderOut(nil)
    }
}

/// Fictional fixtures for public screenshots (`--snap-panes <dir> --sample`). Installed through
/// override hooks on the stores; nothing is written to the real history, stats, dictionary or meetings.
@MainActor
enum SampleData {
    static func install() {
        let now = Date()
        let cal = Calendar.current
        let texts = [
            "Draft the launch note for the Tuesday release and send it to the team.",
            "Remind me to review the onboarding copy before the design sync on Thursday.",
            "Thanks for the update, I will look at the pricing page tomorrow morning.",
            "Let's move the planning call to Friday afternoon and share the agenda beforehand.",
            "The new export option should keep the original formatting and add a short summary.",
            "Can you check whether the beta build includes the latest accessibility fixes?",
            "Add a line to the changelog about faster startup and the improved search results.",
            "Great progress this week, the checkout flow now feels much simpler for new users."]
        HistoryStore.sampleOverride = texts.enumerated().map { i, t in
            HistoryEntry(date: now.addingTimeInterval(-Double(i) * 5400 - 600), text: t, seconds: Double(t.split(separator: " ").count) / 2.4)
        }
        let words = [820, 1240, 0, 1510, 980, 1330, 640, 0, 1420, 1180, 1600, 1090, 1350, 1210]
        var daily: [String: Int] = [:]
        for (i, w) in words.enumerated() {
            if let day = cal.date(byAdding: .day, value: i - 13, to: now) { daily[Stats.dayKey(day)] = w }
        }
        Stats.useSampleDefaults([
            "lifetimeWords": 18_400, "lifetimeTimedWords": 18_000, "lifetimeSeconds": 9_900.0,
            "lifetimeDictations": 410, "fixesAccepted": 12, "meetingsCount": 5,
            "dailyWords": daily,
            "appWords": ["com.apple.mail": 6_200, "com.apple.Notes": 4_900, "com.tinyspeck.slackmacgap": 4_100, "com.apple.Safari": 3_200]])
        DictionaryStore.sampleOverride = DictionaryData(vocab: ["Kestrel", "Northwind", "Figma", "Roadmap"], replacements: [])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-sample-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        MeetingArchive.directoryOverride = dir
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let stamp = f.string(from: now.addingTimeInterval(-26 * 3600))
        let md = """
        Duration: 12:40 \u{00B7} You \u{00B7} Priya \u{00B7} Arjun

        [0:04] **You**: Thanks for joining. Let's start with where the release stands.
        [0:19] **Priya**: The design review is done and the last two screens are signed off.
        [1:32] **Arjun**: Engineering is on track, we only need one more pass on the export flow.
        [3:10] **You**: Good. Can we freeze the scope by Wednesday and test on Thursday?
        [3:41] **Priya**: That works for me, I will share the final assets tomorrow.
        [4:25] **Arjun**: Agreed. I will post the test build in the team channel on Thursday morning.

        """
        let url = dir.appendingPathComponent("meeting-\(stamp).md")
        try? md.write(to: url, atomically: true, encoding: .utf8)
        func spk(_ n: String, _ talk: Double, _ pct: Double, _ w: Int, _ wpm: Double, _ turns: Int, _ mono: Double, _ intr: Int) -> MeetingStats.Speaker {
            .init(name: n, talkSeconds: talk, sharePct: pct, words: w, wpm: wpm, turns: turns, longestMonologue: mono, interruptions: intr)
        }
        let stats = MeetingStats(date: now.addingTimeInterval(-26 * 3600), you: "You", duration: 760,
                                 speakers: [spk("You", 290, 45, 740, 153, 14, 48, 1), spk("Priya", 230, 36, 590, 154, 11, 62, 0), spk("Arjun", 120, 19, 310, 155, 8, 35, 1)],
                                 questionsPerHour: 14, fillersPerMinute: 1.8)
        MeetingStatsStore.save(stats, transcript: url)
        MeetingArchive.saveSummary("**Release status.** Design is signed off; engineering needs one more pass on export.\n\n- Freeze scope by Wednesday\n- Test build posted Thursday morning", for: url)
    }
}
