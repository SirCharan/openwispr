import Foundation
import Network

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
    /// Meeting-clock seconds; nil when no meeting is recording (posts are then ignored).
    var clock: () -> TimeInterval? = { nil }
    var onJoined: () -> Void = {}
    var onLeft: () -> Void = {}
    private(set) var lastJoined: Date?
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
        if ok { listener = l; boundPort = l.port?.rawValue } else { l.cancel() }
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
            case .request(let method, let path, let body):
                self.reply(c, method: method, path: path, body: body)
            default: self.send(c, "HTTP/1.1 400 Bad Request\r\n")
            }
        }
    }

    enum Parsed { case need, bad, request(String, String, Data) }

    /// Pure. Minimal HTTP/1.1: request line, headers to CRLFCRLF, Content-Length body (≤64 KB).
    nonisolated static func parse(_ buf: Data) -> Parsed {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return buf.count > 16_384 ? .bad : .need }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return .bad }
        var len = 0
        for l in lines.dropFirst() {
            let kv = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == "content-length" { len = Int(kv[1]) ?? -1 }
        }
        guard len >= 0, len <= 65_536 else { return .bad }
        let body = buf[end.upperBound...]
        if body.count < len { return .need }
        return .request(String(parts[0]), String(parts[1]), Data(body.prefix(len)))
    }

    private nonisolated func reply(_ c: NWConnection, method: String, path: String, body: Data) {
        guard path == "/meet" else { return send(c, "HTTP/1.1 404 Not Found\r\n") }
        let cors = "Access-Control-Allow-Origin: *\r\n"
        switch method {
        case "OPTIONS":
            send(c, "HTTP/1.1 204 No Content\r\n" + cors + "Access-Control-Allow-Methods: POST\r\nAccess-Control-Allow-Headers: content-type\r\nAccess-Control-Max-Age: 600\r\n")
        case "POST":
            send(c, "HTTP/1.1 204 No Content\r\n" + cors)
            Task { @MainActor in self.handle(body) }
        default: send(c, "HTTP/1.1 405 Method Not Allowed\r\n")
        }
    }

    private nonisolated func send(_ c: NWConnection, _ head: String) {
        c.send(content: Data((head + "Content-Length: 0\r\nConnection: close\r\n\r\n").utf8), contentContext: .finalMessage,
               isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: - Events

    private struct Payload: Decodable {
        struct P: Decodable { let name: String; let speaking: Bool? }
        let v: Int?
        let event: String
        let meeting: String?
        let participants: [P]?
    }

    func handle(_ body: Data) {
        guard let p = try? JSONDecoder().decode(Payload.self, from: body) else { return }
        switch p.event {
        case "roster":
            guard let t = clock() else { return }
            let ps = p.participants ?? []
            timeline.record(t: t, names: ps.map(\.name), speaking: ps.filter { $0.speaking == true }.map(\.name))
        case "joined": lastJoined = Date(); onJoined()
        case "left": lastJoined = nil; onLeft()
        default: break
        }
    }

    static func selfTest() async {
        let s = MeetRosterServer()
        var t = 0.0
        s.clock = { t += 1; return t }
        let up = await s.start(port: 0)
        precondition(up, "listener start")
        guard let port = s.boundPort else { preconditionFailure("no port") }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/meet")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data(#"{"v":1,"event":"roster","meeting":"x","participants":[{"name":"A","speaking":true},{"name":"You","speaking":false}]}"#.utf8)
        let (_, resp) = try! await URLSession.shared.data(for: req)
        precondition((resp as? HTTPURLResponse)?.statusCode == 204, "POST status")
        try? await Task.sleep(for: .milliseconds(200))
        precondition(s.timeline.roster == ["A", "You"] && s.timeline.samples.map(\.name) == ["A"], "timeline recorded")
        req.httpMethod = "OPTIONS"; req.httpBody = nil
        let (_, pre) = try! await URLSession.shared.data(for: req)
        precondition((pre as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Methods") == "POST", "preflight")
        if case .bad = parse(Data("POST /meet HTTP/1.1\r\nContent-Length: 70000\r\n\r\n".utf8)) {} else { preconditionFailure("oversize body") }
        s.stop()
        print("MeetRosterServer.selfTest PASS")
    }
}
