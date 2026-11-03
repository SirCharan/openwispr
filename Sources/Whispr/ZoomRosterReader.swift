import AppKit
import ApplicationServices

/// Reads participant names and the active speaker from Zoom's Accessibility tree while a meeting
/// records, and maps them onto diarized speakers at Stop. UNTESTED on a live call (no Zoom on the
/// dev Mac): the label formats below follow Zoom's documented AX structure, and every element
/// role/value seen is logged at debug level so the parser can be fixed from a real dump.
@MainActor
final class ZoomRosterReader {
    private static let zoomID = "us.zoom.xos"
    private static var nudged = false

    /// (meeting-clock seconds, who the Zoom UI marks as speaking)
    private(set) var timeline: [(t: TimeInterval, name: String)] = []
    private(set) var roster: Set<String> = []

    private let isZoom: () -> Bool
    private let clock: () -> TimeInterval?   // nil while paused
    private var timer: Timer?
    private var lastRefresh = Date.distantPast

    init(isZoom: @escaping () -> Bool, clock: @escaping () -> TimeInterval?) {
        self.isZoom = isZoom
        self.clock = clock
    }

    func start() {
        timeline.removeAll(); roster.removeAll(); lastRefresh = .distantPast
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard isZoom(), let t = clock() else { return }
        guard Permissions.hasAccessibility else {
            if !Self.nudged { Self.nudged = true; Permissions.requestAccessibility() } // existing nudge, once
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.zoomID).first else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        let refresh = Date().timeIntervalSince(lastRefresh) >= 15
        if refresh { lastRefresh = Date() }

        var speaker: String?
        var names: Set<String> = []
        var seen = 0
        func walk(_ el: AXUIElement, _ depth: Int, _ inMeeting: Bool) {
            guard depth < 14, seen < 1500 else { return }
            seen += 1
            let role = Self.str(el, kAXRoleAttribute) ?? "?"
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { Self.str(el, $0) }
            let title = Self.str(el, kAXTitleAttribute) ?? ""
            let meeting = inMeeting || (role == kAXWindowRole && title.contains("Zoom Meeting"))
            if refresh, meeting, !labels.isEmpty {
                Log.audio.debug("zoom AX d\(depth, privacy: .public) \(role, privacy: .public) \(labels.joined(separator: " | "), privacy: .public)")
            }
            if meeting {
                for l in labels {
                    if let p = Self.parse(l) {
                        names.insert(p.name)
                        if p.speaking { speaker = p.name }
                    }
                }
            }
            var kids: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                for k in arr { walk(k, depth + 1, meeting) }
            }
        }
        walk(root, 0, false)
        if refresh {
            if !names.isEmpty { roster = names }
            Log.audio.debug("zoom AX refresh: \(seen, privacy: .public) nodes, roster=\(self.roster.sorted().joined(separator: ", "), privacy: .public)")
        }
        if let s = speaker { timeline.append((t, s)) }
    }

    private static func str(_ el: AXUIElement, _ attr: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Pure. Gallery tiles and participant rows read like "Asha Rao, Computer audio unmuted, Video on"
    /// (speaking tiles add "speaking" / "Active speaker"). Returns nil for anything else.
    nonisolated static func parse(_ label: String) -> (name: String, speaking: Bool)? {
        let low = label.lowercased()
        guard low.contains("audio") || low.contains("video") || low.contains("speaking") else { return nil }
        guard let comma = label.firstIndex(of: ",") else { return nil }
        let name = label[..<comma].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count < 60 else { return nil }
        return (name, low.contains("speaking") || low.contains("active speaker"))
    }

    /// Pure. For each diarized speaker, the dominant roster name if it covers ≥60% of the
    /// speaker's talk time (each timeline sample ≈ 1 s). A name is given to one speaker only.
    nonisolated static func names(segments: [Diarizer.Segment], timeline: [(t: TimeInterval, name: String)]) -> [String: String] {
        var talk: [String: Double] = [:]
        var votes: [String: [String: Double]] = [:]
        for s in segments {
            talk[s.speaker, default: 0] += s.end - s.start
            for p in timeline where p.t >= s.start && p.t < s.end { votes[s.speaker, default: [:]][p.name, default: 0] += 1 }
        }
        var best: [(speaker: String, name: String, share: Double)] = []
        for (sp, v) in votes {
            guard let top = v.max(by: { $0.value < $1.value }), let total = talk[sp], total > 0 else { continue }
            let share = top.value / total
            if share >= 0.6 { best.append((sp, top.key, share)) }
        }
        var out: [String: String] = [:]
        for b in best.sorted(by: { $0.share > $1.share }) where !out.values.contains(b.name) { out[b.speaker] = b.name }
        return out
    }

    static func selfTest() {
        precondition(parse("Asha Rao, Computer audio unmuted, Video on")?.speaking == false, "parse idle")
        let sp = parse("Asha Rao, Computer audio unmuted, Active speaker")
        precondition(sp?.name == "Asha Rao" && sp?.speaking == true, "parse speaking")
        precondition(parse("Leave meeting") == nil, "parse junk")
        let segs = [Diarizer.Segment(speaker: "Speaker A", start: 0, end: 10),
                    Diarizer.Segment(speaker: "Speaker B", start: 10, end: 20)]
        var tl: [(t: TimeInterval, name: String)] = (0..<8).map { (TimeInterval($0), "Asha") }
        tl += (10..<14).map { (TimeInterval($0), "Ben") } // 4 of 10 s: below 60%
        let m = names(segments: segs, timeline: tl)
        precondition(m == ["Speaker A": "Asha"], "dominant ≥60% only: \(m)")
        print("ZoomRosterReader.selfTest PASS")
    }
}
