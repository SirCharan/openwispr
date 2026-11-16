import Foundation
import Network
import AppKit
import QuartzCore

/// Loopback-only HTTP listener. The Chrome extension in extensions/meet-names POSTs Meet rosters
/// to http://127.0.0.1:47891/meet; they feed the same RosterTimeline the Zoom path uses.
@MainActor
final class MeetRosterServer {
    static let defaultPort: UInt16 = 47891
    static var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: "meetRosterPort")
        return p > 0 && p < 65536 ? UInt16(p) : defaultPort
    }

    let timeline = RosterTimeline()
    /// Meeting-clock seconds; nil when no meeting is recording (posts are then buffered for ~60 s).
    private(set) var clock: () -> TimeInterval? = { nil }
    var onJoined: () -> Void = {}
    var onLeft: () -> Void = {}
    /// Fires when a `left` event for the recorded meeting is not followed by a roster event within `leaveGrace`.
    var onAutoStop: () -> Void = {}
    var autoStopEnabled: () -> Bool = { Settings.meetingAutoStop }
    var leaveGrace: TimeInterval = 10
    var hostNow: () -> Double = { CACurrentMediaTime() }
    private var leaveTask: Task<Void, Never>?
    /// Meet code of the meeting being recorded (set from the first roster event, or the buffer).
    private(set) var activeMeeting: String?
    /// Latest roster size and when anyone was last shown speaking (cleared on joined/left).
    private(set) var lastParticipants = 0
    private(set) var lastSpeakingAt: Date?
    /// Auto-stop on `left` is trusted only for a meeting that was really being recorded: roster events with
    /// someone speaking arrived for `activeMeeting` during the recording, and the meeting was adopted in the
    /// first `adoptWindow` seconds of it (or the recording started on a Meet window).
    private(set) var speakingSeen = false
    private(set) var adoptedAt: TimeInterval = 0
    private(set) var startedOnMeetWindow = false
    static let adoptWindow = 120.0
    private var autoStopTrusted: Bool { speakingSeen && (startedOnMeetWindow || adoptedAt <= Self.adoptWindow) }
    /// The only Origin a Meet content script's cross-origin fetch carries (the extension has no background worker).
    nonisolated static let allowedOrigin = "https://meet.google.com"
    private struct Tick { let host: Double; let meeting: String?; let names: [String]; let speaking: [String]; let selfName: String? }
    private var buffer: [Tick] = []
    static let bufferSeconds = 60.0
    private(set) var lastJoined: Date?
    /// Last valid event from the extension (any type). `everConnected` survives relaunches.
    private(set) var lastEventAt: Date?
    static var everConnected: Bool {
        get { UserDefaults.standard.bool(forKey: "meetExtEverConnected") }
        set { UserDefaults.standard.set(newValue, forKey: "meetExtEverConnected") }
    }

    /// Pure. One status line for the Meetings pane. Connected only if an event arrived in the last 10 min;
    /// then it says whether names are in use (recording and someone seen speaking).
    nonisolated static func statusText(everConnected: Bool, lastEventAt: Date?, now: Date = Date(),
                                       participants: Int = 0, lastSpeakingAt: Date? = nil, recording: Bool = false) -> (text: String, connected: Bool) {
        guard let t = lastEventAt, now.timeIntervalSince(t) < 600 else {
            return (everConnected ? "Not seen recently. Is Chrome open with the extension on?" : "Extension not loaded", false)
        }
        let seen: String
        if let s = lastSpeakingAt {
            let secs = Int(now.timeIntervalSince(s))
            seen = secs < 5 ? "someone speaking now" : secs < 60 ? "last speaker \(secs)s ago" : "last speaker \(secs / 60) min ago"
        } else { seen = "" }
        let detail = [participants > 0 ? "\(participants) in call" : "", seen].filter { !$0.isEmpty }.joined(separator: ", ")
        let head = !recording ? "Connected but not recording" : lastSpeakingAt == nil ? "Connected, nobody detected speaking yet" : "Connected, names in use"
        return (detail.isEmpty ? head : "\(head) (\(detail))", true)
    }

    /// The three steps shown next to the Set up button and in the in-meeting hint.
    static let setupSteps = "1. Turn on Developer mode. 2. Click Load unpacked. 3. Pick the meet-names folder that Finder shows."

    /// Opens chrome://extensions and reveals the bundled extension folder.
    static func openSetup() {
        let cfg = NSWorkspace.OpenConfiguration()
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.open([URL(string: "chrome://extensions")!], withApplicationAt: chrome, configuration: cfg)
        }
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("meet-names") {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }
    var joinedRecently: Bool { lastJoined.map { Date().timeIntervalSince($0) < 60 } ?? false }

    private var listener: NWListener?
    private(set) var boundPort: UInt16?
    private let queue = DispatchQueue(label: "whispr.meet-roster", qos: .utility)

    /// Starts on `port` (0 = ephemeral). Returns once ready or failed.
    @discardableResult
    func start(port: UInt16? = nil) async -> Bool {
        let port = port ?? Self.port
        stop()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? 0)
        guard let l = try? NWListener(using: params) else { return false }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let ok: Bool = await withCheckedContinuation { cont in
            let once = NSLock(); nonisolated(unsafe) var done = false
            l.stateUpdateHandler = { state in
                let result: Bool
                switch state {
                case .ready: result = true
                case .failed, .cancelled: result = false
                default: return
                }
                once.lock(); defer { once.unlock() }
                guard !done else { return }
                done = true; cont.resume(returning: result)
            }
            l.start(queue: queue)
        }
        if ok { listener = l; boundPort = l.port?.rawValue; Log.app.info("meet-ext: listening on 127.0.0.1:\(self.boundPort ?? port, privacy: .public)") } else { l.cancel() }
        return ok
    }

    func stop() { listener?.cancel(); listener = nil; boundPort = nil }

    // MARK: - HTTP

    private nonisolated func accept(_ c: NWConnection) {
        if case let .hostPort(host, _) = c.endpoint {
            let h = "\(host)"
            guard h.hasPrefix("127.") || h.hasPrefix("::1") || h.contains("::ffff:127.") else { c.cancel(); return }
        }
        c.start(queue: queue)
        read(c, Data())
    }

    private nonisolated func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = buf
            if let data { buf.append(data) }
            switch Self.parse(buf) {
            case .need where err == nil && !done && buf.count < 80_000: self.read(c, buf)
            case .request(let method, let path, let body, let origin):
                self.reply(c, method: method, path: path, body: body, origin: origin)
            default: self.send(c, "HTTP/1.1 400 Bad Request\r\n")
            }
        }
    }

    enum Parsed { case need, bad, request(String, String, Data, String?) }

    /// Pure. Minimal HTTP/1.1: request line, headers to CRLFCRLF, Content-Length body (≤64 KB).
    nonisolated static func parse(_ buf: Data) -> Parsed {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return buf.count > 16_384 ? .bad : .need }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return .bad }
        var len = 0
        var origin: String?
        for l in lines.dropFirst() {
            let kv = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == "content-length" { len = Int(kv[1]) ?? -1 }
            if kv.count == 2, kv[0].lowercased() == "origin" { origin = kv[1] }
        }
        guard len >= 0, len <= 65_536 else { return .bad }
        let body = buf[end.upperBound...]
        if body.count < len { return .need }
        return .request(String(parts[0]), String(parts[1]), Data(body.prefix(len)), origin)
    }

    private nonisolated func reply(_ c: NWConnection, method: String, path: String, body: Data, origin: String?) {
        guard path == "/meet" else {
            Log.app.info("meet-ext: rejected path \(path, privacy: .public)")
            return send(c, "HTTP/1.1 404 Not Found\r\n")
        }
        guard origin == Self.allowedOrigin else {
            Log.app.info("meet-ext: rejected origin \(origin ?? "-", privacy: .public)")
            return send(c, "HTTP/1.1 403 Forbidden\r\n")
        }
        let cors = "Access-Control-Allow-Origin: \(Self.allowedOrigin)\r\nVary: Origin\r\n"
        switch method {
        case "OPTIONS":
            send(c, "HTTP/1.1 204 No Content\r\n" + cors + "Access-Control-Allow-Methods: POST\r\nAccess-Control-Allow-Headers: content-type\r\nAccess-Control-Max-Age: 600\r\n")
        case "POST":
            send(c, "HTTP/1.1 204 No Content\r\n" + cors)
            Task { @MainActor in self.handle(body) }
        default:
            Log.app.info("meet-ext: rejected method \(method, privacy: .public)")
            send(c, "HTTP/1.1 405 Method Not Allowed\r\n")
        }
    }

    private nonisolated func send(_ c: NWConnection, _ head: String) {
        c.send(content: Data((head + "Content-Length: 0\r\nConnection: close\r\n\r\n").utf8), contentContext: .finalMessage,
               isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: - Events

    private struct Payload: Decodable {
        /// `self` is optional (extension 0.2.0+): true on the local user's own tile.
        struct P: Decodable {
            let name: String; let speaking: Bool?; let isSelf: Bool?
            enum CodingKeys: String, CodingKey { case name, speaking, isSelf = "self" }
        }
        let v: Int?
        let event: String
        let meeting: String?
        let participants: [P]?
    }

    func handle(_ body: Data) {
        guard let p = try? JSONDecoder().decode(Payload.self, from: body) else {
            Log.app.info("meet-ext: rejected undecodable body (\(body.count, privacy: .public) bytes)")
            return
        }
        lastEventAt = Date(); Self.everConnected = true
        let ps = p.participants ?? []
        Log.app.info("meet-ext: \(p.event, privacy: .public) meeting=\(p.meeting ?? "-", privacy: .public) participants=\(ps.count, privacy: .public) speaking=\(ps.filter { $0.speaking == true }.count, privacy: .public)")
        switch p.event {
        case "roster":
            let names = ps.map(\.name), speaking = ps.filter { $0.speaking == true }.map(\.name)
            let me = ps.first { $0.isSelf == true }?.name
            lastParticipants = ps.count
            if !speaking.isEmpty { lastSpeakingAt = Date() }
            if let t = clock() {
                timeline.record(t: t, names: names, speaking: speaking, selfName: me)
                if activeMeeting == nil, let m = p.meeting { activeMeeting = m; adoptedAt = t }
                if p.meeting == activeMeeting {
                    cancelLeave()
                    if !speaking.isEmpty { speakingSeen = true }
                }
            } else {
                let h = hostNow()
                buffer.append(Tick(host: h, meeting: p.meeting, names: names, speaking: speaking, selfName: me))
                buffer.removeAll { h - $0.host > Self.bufferSeconds }
            }
        case "joined":
            lastJoined = Date(); lastSpeakingAt = nil; onJoined()
            if clock() != nil, p.meeting == activeMeeting { cancelLeave() }
        case "left":
            lastJoined = nil; lastSpeakingAt = nil; onLeft()
            if clock() != nil, autoStopEnabled(), let m = p.meeting, m == activeMeeting, autoStopTrusted, leaveTask == nil {
                Log.app.info("meet-ext: left \(m, privacy: .public), stopping in \(self.leaveGrace, privacy: .public)s unless it returns")
                leaveTask = Task { [weak self] in
                    guard let grace = self?.leaveGrace else { return }
                    try? await Task.sleep(for: .seconds(grace))
                    guard !Task.isCancelled, let self else { return }
                    self.leaveTask = nil
                    self.onAutoStop()
                }
            }
        default: Log.app.info("meet-ext: rejected unknown event \(p.event, privacy: .public)")
        }
    }

    private func cancelLeave() { leaveTask?.cancel(); leaveTask = nil }

    /// A recording starts: wire the timeline whatever window is frontmost and seed it with the last ~60 s of posts.
    func attach(clock: @escaping () -> TimeInterval?, toClock: (Double) -> TimeInterval, onMeetWindow: Bool = false) {
        cancelLeave()
        speakingSeen = false; adoptedAt = 0; startedOnMeetWindow = onMeetWindow
        timeline.reset()
        let h = hostNow()
        let recent = buffer.filter { h - $0.host <= Self.bufferSeconds }
        for tk in recent { timeline.record(t: toClock(tk.host), names: tk.names, speaking: tk.speaking, selfName: tk.selfName) }
        activeMeeting = recent.last?.meeting
        buffer.removeAll()
        self.clock = clock
    }

    /// The recording ended (or has not started): posts go back to the buffer.
    func detach() { cancelLeave(); clock = { nil }; activeMeeting = nil; speakingSeen = false }

    static func selfTest() async {
        let s = MeetRosterServer()
        var t = 0.0
        s.attach(clock: { t += 1; return t }, toClock: { $0 })
        let up = await s.start(port: 0)
        precondition(up, "listener start")
        guard let port = s.boundPort else { preconditionFailure("no port") }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/meet")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(allowedOrigin, forHTTPHeaderField: "Origin")
        req.httpBody = Data(#"{"v":1,"event":"roster","meeting":"x","participants":[{"name":"A","speaking":true},{"name":"You","speaking":false}]}"#.utf8)
        let (_, resp) = try! await URLSession.shared.data(for: req)
        precondition((resp as? HTTPURLResponse)?.statusCode == 204, "POST status")
        precondition((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == allowedOrigin, "CORS origin echoed, not *")
        try? await Task.sleep(for: .milliseconds(200))
        precondition(s.timeline.roster == ["A", "You"] && s.timeline.samples.map(\.name) == ["A"], "timeline recorded")
        req.httpMethod = "OPTIONS"; req.httpBody = nil
        let (_, pre) = try! await URLSession.shared.data(for: req)
        precondition((pre as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Methods") == "POST", "preflight")
        // Origin gate: other origins, a chrome-extension origin and no Origin at all are refused.
        for bad in ["https://evil.example", "chrome-extension://abcdefgh", "https://meet.google.com.evil.example", "http://meet.google.com", nil] as [String?] {
            var r = req; r.httpMethod = "POST"; r.setValue(bad, forHTTPHeaderField: "Origin")
            r.httpBody = Data(#"{"v":1,"event":"roster","meeting":"x","participants":[{"name":"Evil","speaking":true}]}"#.utf8)
            let (_, rr) = try! await URLSession.shared.data(for: r)
            precondition((rr as? HTTPURLResponse)?.statusCode == 403, "origin \(bad ?? "none") not refused")
            precondition((rr as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil, "403 carries CORS")
        }
        try? await Task.sleep(for: .milliseconds(100))
        precondition(!s.timeline.roster.contains("Evil"), "refused origin reached the timeline")
        if case .bad = parse(Data("POST /meet HTTP/1.1\r\nContent-Length: 70000\r\n\r\n".utf8)) {} else { preconditionFailure("oversize body") }
        s.stop()
        // Payload with and without `self`; the flag names the local user.
        s.handle(Data(#"{"v":1,"event":"roster","meeting":"x","participants":[{"name":"Me","speaking":false,"self":true},{"name":"A","speaking":true}]}"#.utf8))
        precondition(s.timeline.selfName == "Me" && s.lastParticipants == 2 && s.lastSpeakingAt != nil, "self flag parsed")
        s.handle(Data(#"{"v":1,"event":"roster","meeting":"x","participants":[{"name":"A","speaking":true}]}"#.utf8))
        precondition(s.timeline.selfName == "Me", "payload without self keeps earlier self")
        // Buffer while idle, then seed with the last 60 s only.
        let b = MeetRosterServer()
        var host = 1000.0
        b.hostNow = { host }
        b.handle(Data(#"{"v":1,"event":"roster","meeting":"m1","participants":[{"name":"Old","speaking":true}]}"#.utf8))
        host = 1050
        b.handle(Data(#"{"v":1,"event":"roster","meeting":"m1","participants":[{"name":"Ann","speaking":true},{"name":"You","speaking":false,"self":true}]}"#.utf8))
        host = 1065
        b.attach(clock: { 5 }, toClock: { $0 - 1060 })
        precondition(b.timeline.roster == ["Ann", "You"] && b.timeline.states.map(\.t) == [-10] && b.timeline.selfName == "You", "buffer seeded (old tick pruned)")
        precondition(b.activeMeeting == "m1", "active meeting from buffer")
        // Auto-stop: `left` arms a grace timer, a roster event for the same meeting cancels it.
        b.leaveGrace = 0.2; b.autoStopEnabled = { true }
        var stops = 0
        b.onAutoStop = { stops += 1 }
        let left = Data(#"{"v":1,"event":"left","meeting":"m1"}"#.utf8)
        // 4b: no speaking seen live yet, so `left` is not trusted (a roster seeded from the buffer does not count).
        b.handle(left)
        try? await Task.sleep(for: .milliseconds(400))
        precondition(stops == 0, "left without live speaking must not stop")
        b.handle(Data(#"{"v":1,"event":"roster","meeting":"m1","participants":[{"name":"Ann","speaking":true}]}"#.utf8))
        b.handle(left)
        b.handle(Data(#"{"v":1,"event":"roster","meeting":"m1","participants":[{"name":"Ann","speaking":false}]}"#.utf8))
        try? await Task.sleep(for: .milliseconds(400))
        precondition(stops == 0, "grace cancelled by roster")
        b.handle(Data(#"{"v":1,"event":"left","meeting":"other"}"#.utf8))
        try? await Task.sleep(for: .milliseconds(400))
        precondition(stops == 0, "other meeting ignored")
        b.handle(left)
        try? await Task.sleep(for: .milliseconds(400))
        precondition(stops == 1, "auto-stop after grace")
        // 4b: a meeting joined late in some other recording is not adopted for auto-stop; on a Meet window it is.
        let late = MeetRosterServer()
        late.leaveGrace = 0.2; late.autoStopEnabled = { true }
        var lateStops = 0
        late.onAutoStop = { lateStops += 1 }
        late.attach(clock: { 500 }, toClock: { $0 })
        late.handle(Data(#"{"v":1,"event":"roster","meeting":"z","participants":[{"name":"Ann","speaking":true}]}"#.utf8))
        late.handle(Data(#"{"v":1,"event":"left","meeting":"z"}"#.utf8))
        try? await Task.sleep(for: .milliseconds(400))
        precondition(lateStops == 0, "meeting adopted at t=500 stopped the recording")
        late.attach(clock: { 500 }, toClock: { $0 }, onMeetWindow: true)
        late.handle(Data(#"{"v":1,"event":"roster","meeting":"z","participants":[{"name":"Ann","speaking":true}]}"#.utf8))
        late.handle(Data(#"{"v":1,"event":"left","meeting":"z"}"#.utf8))
        try? await Task.sleep(for: .milliseconds(400))
        precondition(lateStops == 1, "Meet-window recording did not auto-stop")
        let early = MeetRosterServer()
        early.leaveGrace = 0.2; early.autoStopEnabled = { true }
        var earlyStops = 0
        early.onAutoStop = { earlyStops += 1 }
        early.attach(clock: { 90 }, toClock: { $0 })
        early.handle(Data(#"{"v":1,"event":"roster","meeting":"z","participants":[{"name":"Ann","speaking":true}]}"#.utf8))
        early.handle(Data(#"{"v":1,"event":"left","meeting":"z"}"#.utf8))
        try? await Task.sleep(for: .milliseconds(400))
        precondition(earlyStops == 1, "meeting adopted at t=90 did not auto-stop")
        b.autoStopEnabled = { false }
        b.handle(left)
        try? await Task.sleep(for: .milliseconds(400))
        precondition(stops == 1, "setting off")
        let now = Date()
        precondition(statusText(everConnected: false, lastEventAt: nil, now: now).text == "Extension not loaded", "status never")
        precondition(statusText(everConnected: true, lastEventAt: now - 120, now: now) == ("Connected but not recording", true), "status idle")
        precondition(statusText(everConnected: true, lastEventAt: now - 2, now: now, participants: 3, recording: true).text == "Connected, nobody detected speaking yet (3 in call)", "status no speech")
        precondition(statusText(everConnected: true, lastEventAt: now - 2, now: now, participants: 3, lastSpeakingAt: now - 12, recording: true).text == "Connected, names in use (3 in call, last speaker 12s ago)", "status in use")
        precondition(!statusText(everConnected: true, lastEventAt: now - 3600, now: now).connected, "status stale")
        print("MeetRosterServer.selfTest PASS")
    }
}
