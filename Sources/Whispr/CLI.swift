import AppKit

/// `openwispr <command>`: JSON envelope `{ok, command, data, meta:{version}, error}` on stdout.
/// Reads open the stores directly; state changes go through the `openwispr://` URL scheme so the
/// running app owns every write (adapted from Muesli's MuesliCLI.swift).
enum CLI {
    static let commands: [(name: String, usage: String)] = [
        ("transcribe", "transcribe <file> [--model M] [--lang L] [--format json]"),
        ("history list", "history list [--limit N]"),
        ("history get", "history get <id>"),
        ("history search", "history search <query>"),
        ("meetings list", "meetings list"),
        ("meetings get", "meetings get <stamp>"),
        ("dictionary add", "dictionary add <term> [--replace <text>]"),
        ("dictation start", "dictation start"),
        ("dictation stop", "dictation stop"),
        ("meeting start", "meeting start"),
        ("meeting stop", "meeting stop"),
        ("skill install", "skill install"),
        ("spec", "spec"),
        ("info", "info"),
    ]

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    static func isAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "org.openwispr.app").isEmpty
    }

    static func open(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", url.absoluteString]
        try? p.run()
        p.waitUntilExit()
    }

    /// Entry point for `--cli …`; `transcribe` is handled by the caller (it needs the model).
    static func main(_ args: [String]) -> Int32 {
        let (code, json) = run(args, opener: open, appRunning: isAppRunning)
        print(json)
        return code
    }

    static func envelope(_ command: String, data: Any? = nil, error: String? = nil) -> String {
        let obj: [String: Any] = [
            "ok": error == nil, "command": command, "data": data ?? NSNull(),
            "meta": ["version": version], "error": error ?? NSNull(),
        ]
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    private static func opt(_ name: String, _ a: [String]) -> String? {
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    private static let iso = ISO8601DateFormatter()

    static func run(_ args: [String], opener: (URL) -> Void, appRunning: () -> Bool) -> (code: Int32, json: String) {
        let cmd = args.prefix(2).joined(separator: " ")
        func ok(_ data: Any?) -> (Int32, String) { (0, envelope(cmd, data: data)) }
        func fail(_ msg: String) -> (Int32, String) { (1, envelope(cmd, error: msg)) }
        let a = Array(args.dropFirst(2))
        switch args.first ?? "" {
        case "spec":
            return (0, envelope("spec", data: ["commands": commands.map { ["name": $0.name, "usage": $0.usage] },
                                               "urlScheme": ["openwispr://dictation/start|stop", "openwispr://meeting/start|stop",
                                                             "openwispr://open/<pane>", "openwispr://dictionary/add?term=&replace="]]))
        case "skill":
            guard args.dropFirst().first == "install" else { return fail("usage: skill install") }
            guard let src = Bundle.main.resourceURL?.appendingPathComponent("skills/openwispr-agent"),
                  FileManager.default.fileExists(atPath: src.path) else { return fail("skill not bundled in this build") }
            let dst = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/openwispr-agent")
            do {
                try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: src, to: dst)
            } catch { return fail("could not install skill: \(error.localizedDescription)") }
            return ok(["installed": dst.path])
        case "info":
            return (0, envelope("info", data: ["version": version, "appRunning": appRunning(),
                                               "historyEntries": HistoryStore.load().count,
                                               "meetings": MeetingArchive.list().count,
                                               "meetingsDir": MeetingArchive.directory.path]))
        case "history":
            let h = HistoryStore.load()
            func row(_ e: HistoryEntry) -> [String: Any] {
                ["id": e.id.uuidString, "date": iso.string(from: e.date), "words": e.words, "text": e.text]
            }
            switch args.dropFirst().first {
            case "list": return ok(h.prefix(Int(opt("--limit", a) ?? "") ?? 20).map(row))
            case "get":
                guard let id = a.first, let e = h.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else { return fail("no history entry with that id") }
                return ok(row(e))
            case "search":
                let q = a.joined(separator: " ")
                guard !q.isEmpty else { return fail("usage: history search <query>") }
                return ok(h.filter { $0.text.localizedCaseInsensitiveContains(q) }.map(row))
            default: return fail("usage: history list|get|search")
            }
        case "meetings":
            switch args.dropFirst().first {
            case "list":
                return ok(MeetingArchive.list().map {
                    ["stamp": $0.stamp, "date": iso.string(from: $0.date), "duration": $0.duration,
                     "speakers": $0.speakers, "hasSummary": $0.hasSummary] as [String: Any]
                })
            case "get":
                guard let stamp = a.first, let m = MeetingArchive.load(stamp: stamp) else { return fail("no meeting with that stamp") }
                var d: [String: Any] = ["stamp": stamp, "lines": m.lines.map { ["speaker": $0.speaker, "start": $0.start, "text": $0.text] as [String: Any] }]
                if let s = MeetingArchive.loadSummary(for: MeetingArchive.fileURL(stamp: stamp)) { d["summary"] = s }
                return ok(d)
            default: return fail("usage: meetings list|get")
            }
        case "dictionary":
            guard args.dropFirst().first == "add", let term = a.first, !term.hasPrefix("--") else { return fail("usage: dictionary add <term> [--replace <text>]") }
            let replace = opt("--replace", a)
            if appRunning() {
                var c = URLComponents(string: "openwispr://dictionary/add")!
                c.queryItems = [URLQueryItem(name: "term", value: term)] + (replace.map { [URLQueryItem(name: "replace", value: $0)] } ?? [])
                opener(c.url!)
            } else {
                addToDictionary(term: term, replace: replace)
            }
            return ok(["added": term, "replace": replace ?? NSNull(), "viaApp": appRunning()])
        case "dictation", "meeting":
            guard let sub = args.dropFirst().first, sub == "start" || sub == "stop" else { return fail("usage: \(args[0]) start|stop") }
            opener(URL(string: "openwispr://\(args[0])/\(sub)")!)
            return ok(["requested": sub])
        default:
            return fail("unknown command; run `openwispr spec`")
        }
    }

    /// Same write the Dictionary pane does: a replacement when `replace` is given, else a vocab term.
    static func addToDictionary(term: String, replace: String?) {
        var d = DictionaryStore.load()
        if let r = replace { d.replacements.append(Replacement(from: term, to: r)) }
        else if !d.vocab.contains(term) { d.vocab.append(term) }
        DictionaryStore.save(d)
    }

    static func selfTest() {
        var opened: [String] = []
        let sample = [HistoryEntry(text: "hello world from the cli"), HistoryEntry(text: "second note")]
        HistoryStore.sampleOverride = sample
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        MeetingArchive.directoryOverride = tmp
        defer { HistoryStore.sampleOverride = nil; MeetingArchive.directoryOverride = nil; try? FileManager.default.removeItem(at: tmp) }
        let stamp = "2026-11-03T08-13-04"
        try? "Duration: 1:05 · You · Speaker A\n\n[0:28] **You**: hi\n".write(to: MeetingArchive.fileURL(stamp: stamp), atomically: true, encoding: .utf8)

        func call(_ s: String, running: Bool = true) -> [String: Any] {
            let (code, json) = run(s.split(separator: " ").map(String.init), opener: { opened.append($0.absoluteString) }, appRunning: { running })
            let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            precondition(["ok", "command", "data", "meta", "error"].allSatisfy { o[$0] != nil }, "CLI envelope shape failed: \(s)")
            precondition((o["meta"] as? [String: Any])?["version"] is String, "CLI meta.version missing: \(s)")
            precondition((o["ok"] as? Bool) == (code == 0), "CLI ok/exit mismatch: \(s)")
            return o
        }
        let spec = call("spec")
        precondition(((spec["data"] as? [String: Any])?["commands"] as? [[String: Any]])?.count == commands.count, "CLI spec failed")
        precondition(call("info")["ok"] as? Bool == true, "CLI info failed")
        precondition((call("history list --limit 1")["data"] as? [Any])?.count == 1, "CLI history list failed")
        precondition((call("history get \(sample[1].id.uuidString)")["data"] as? [String: Any])?["text"] as? String == "second note", "CLI history get failed")
        precondition((call("history search WORLD")["data"] as? [Any])?.count == 1, "CLI history search failed")
        precondition(call("history get nope")["ok"] as? Bool == false, "CLI history get miss failed")
        precondition((call("meetings list")["data"] as? [Any])?.count == 1, "CLI meetings list failed")
        precondition(((call("meetings get \(stamp)")["data"] as? [String: Any])?["lines"] as? [Any])?.count == 1, "CLI meetings get failed")
        precondition(call("dictionary add Kubernetes --replace k8s")["ok"] as? Bool == true
                     && opened.last == "openwispr://dictionary/add?term=Kubernetes&replace=k8s", "CLI dictionary add failed: \(opened)")
        precondition(call("dictation start")["ok"] as? Bool == true && opened.last == "openwispr://dictation/start", "CLI dictation start failed")
        precondition(call("dictation stop")["ok"] as? Bool == true && opened.last == "openwispr://dictation/stop", "CLI dictation stop failed")
        precondition(call("meeting start")["ok"] as? Bool == true && opened.last == "openwispr://meeting/start", "CLI meeting start failed")
        precondition(call("meeting stop")["ok"] as? Bool == true && opened.last == "openwispr://meeting/stop", "CLI meeting stop failed")
        precondition(call("bogus")["ok"] as? Bool == false, "CLI unknown command failed")
        print("CLI.selfTest PASS (\(commands.count) commands)")
    }
}
