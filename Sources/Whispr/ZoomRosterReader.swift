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

    let timeline = RosterTimeline()

    private let isZoom: () -> Bool
    private let clock: () -> TimeInterval?   // nil while paused
    private var timer: Timer?
    private var lastRefresh = Date.distantPast

    init(isZoom: @escaping () -> Bool, clock: @escaping () -> TimeInterval?) {
        self.isZoom = isZoom
        self.clock = clock
    }

    func start() {
        timeline.reset(); lastRefresh = .distantPast
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private let queue = DispatchQueue(label: "whispr.zoom-ax", qos: .utility)
    private var walking = false

    private func tick() {
        guard !walking, isZoom(), let t = clock() else { return }
        guard Permissions.hasAccessibility else {
            if !Self.nudged { Self.nudged = true; Permissions.requestAccessibility() } // existing nudge, once
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.zoomID).first else { return }
        let pid = app.processIdentifier
        let refresh = Date().timeIntervalSince(lastRefresh) >= 15
        if refresh { lastRefresh = Date() }
        walking = true
        queue.async { [weak self] in
            let r = Self.scan(pid: pid, refresh: refresh)
            Task { @MainActor in
                guard let self else { return }
                self.walking = false
                if refresh {
                    Log.audio.debug("zoom AX refresh: \(r.seen, privacy: .public) nodes, roster=\(r.names.sorted().joined(separator: ", "), privacy: .public)")
                }
                self.timeline.record(t: t, names: refresh ? Array(r.names) : [], speaking: r.speaker.map { [$0] } ?? [])
            }
        }
    }

    /// Runs on `queue`. Walks from the "Zoom Meeting" window (app root only if it is not found),
    /// capped at 400 nodes, each element with a 0.2 s AX messaging timeout.
    private nonisolated static func scan(pid: pid_t, refresh: Bool) -> (speaker: String?, names: Set<String>, seen: Int) {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var start = root, inMeeting = false
        var wins: AnyObject?
        if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &wins) == .success,
           let arr = wins as? [AXUIElement] {
            for w in arr {
                AXUIElementSetMessagingTimeout(w, 0.2)
                if (str(w, kAXTitleAttribute) ?? "").contains("Zoom Meeting") { start = w; inMeeting = true; break }
            }
        }
        var speaker: String?
        var names: Set<String> = []
        var seen = 0
        func walk(_ el: AXUIElement, _ depth: Int, _ inMeeting: Bool) {
            guard depth < 14, seen < 400 else { return }
            seen += 1
            AXUIElementSetMessagingTimeout(el, 0.2)
            let role = str(el, kAXRoleAttribute) ?? "?"
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { str(el, $0) }
            let title = str(el, kAXTitleAttribute) ?? ""
            let meeting = inMeeting || (role == kAXWindowRole && title.contains("Zoom Meeting"))
            if refresh, meeting, !labels.isEmpty {
                Log.audio.debug("zoom AX d\(depth, privacy: .public) \(role, privacy: .public) \(labels.joined(separator: " | "), privacy: .public)")
            }
            if meeting {
                for l in labels {
                    if let p = parse(l) {
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
        walk(start, 0, inMeeting)
        return (speaker, names, seen)
    }

    private nonisolated static func str(_ el: AXUIElement, _ attr: String) -> String? {
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

    static func selfTest() {
        precondition(parse("Asha Rao, Computer audio unmuted, Video on")?.speaking == false, "parse idle")
        let sp = parse("Asha Rao, Computer audio unmuted, Active speaker")
        precondition(sp?.name == "Asha Rao" && sp?.speaking == true, "parse speaking")
        precondition(parse("Leave meeting") == nil, "parse junk")
        print("ZoomRosterReader.selfTest PASS")
    }
}
