import AppKit
import CoreImage
import ScreenCaptureKit
import Vision

/// EXPERIMENTAL, untried on a live call. Names meeting speakers from the screen for Meet, Teams and
/// Zoom windows: 1 fps low-res capture of the meeting window, find the coloured active-speaker border
/// (Meet blue, Teams purple, Zoom green), OCR the name strip of that tile, and feed the same
/// RosterTimeline the Zoom AX and Meet extension paths use. Every ~15 s the whole frame is OCR'd
/// for the roster. Extension / AX names win at Stop (MeetingController merges this map last).
@MainActor
final class ScreenSpeakerReader: NSObject {
    enum Kind: String { case meet, teams, zoom
        init(meetingID: String) {
            self = meetingID == "us.zoom.xos" ? .zoom : meetingID.hasPrefix("com.microsoft.teams") ? .teams : .meet
        }
        /// Hue window (degrees) of the active-speaker border.
        var hues: ClosedRange<Double> {
            switch self {
            case .meet: return 200...228
            case .teams: return 230...258
            case .zoom: return 110...160
            }
        }
    }

    let timeline = RosterTimeline()
    private let clock: () -> TimeInterval?
    private var stream: SCStream?
    private let sink: FrameSink

    init(kind: Kind, clock: @escaping () -> TimeInterval?) {
        self.clock = clock
        self.sink = FrameSink(kind: kind)
        super.init()
        sink.onResult = { [weak self] speaker, names in
            Task { @MainActor in
                guard let self, let t = self.clock() else { return }
                self.timeline.record(t: t, names: names, speaking: speaker.map { [$0] } ?? [])
            }
        }
    }

    /// Finds the largest on-screen window classified as `meetingID` and captures it at 1 fps.
    /// No-op without Screen Recording permission (never prompts) or when no window matches.
    func start(meetingID: String) async {
        timeline.reset()
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let win = content.windows.filter { w in
            guard let b = w.owningApplication?.bundleIdentifier, let t = w.title else { return false }
            return MeetingWindowDetector.classify([(b, t)], cptHostRunning: false)?.id == meetingID
        }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let win else { Log.audio.info("screen names: no \(meetingID, privacy: .public) window to capture"); return }
        let cfg = SCStreamConfiguration()
        let scale = min(1, 1280 / max(win.frame.width, 1))
        cfg.width = Int(win.frame.width * scale); cfg.height = Int(win.frame.height * scale)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.queueDepth = 3
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: nil)
        do {
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try await s.startCapture()
            stream = s
            Log.audio.info("screen names: capturing \(win.title ?? "?", privacy: .public) \(cfg.width)x\(cfg.height)")
        } catch {
            Log.audio.error("screen names: capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
    }

    // MARK: - frame pipeline (nonisolated, pure apart from Vision)

    /// Receives frames on `queue`, drops any that arrive while the previous one is still being read.
    final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
        let queue = DispatchQueue(label: "whispr.screen-names", qos: .utility)
        private let work = DispatchQueue(label: "whispr.screen-names.ocr", qos: .utility)
        private let kind: Kind
        private let lock = NSLock()
        private var busy = false
        private var lastRoster = Date.distantPast
        var onResult: (String?, [String]) -> Void = { _, _ in }

        init(kind: Kind) { self.kind = kind }

        func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, let px = sb.imageBuffer,
                  let cg = ScreenSpeakerReader.ciContext.createCGImage(CIImage(cvPixelBuffer: px), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))) else { return }
            lock.lock()
            if busy { lock.unlock(); return }
            busy = true
            let roster = Date().timeIntervalSince(lastRoster) >= 15
            if roster { lastRoster = Date() }
            lock.unlock()
            work.async { [self] in
                let r = ScreenSpeakerReader.analyze(cg, kind: kind, roster: roster)
                lock.lock(); busy = false; lock.unlock()
                onResult(r.speaker, r.names)
            }
        }
    }

    nonisolated static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// One frame: active speaker (OCR of the highlighted tile's name strip) and, when `roster`,
    /// every name-like label on the frame.
    nonisolated static func analyze(_ img: CGImage, kind: Kind, roster: Bool) -> (speaker: String?, names: [String]) {
        var speaker: String?
        if let box = highlightBox(img, hues: kind.hues) {
            // Name label sits bottom-left inside the tile on all three apps.
            let strip = CGRect(x: box.minX + 4, y: box.minY + box.height * 0.7,
                               width: box.width * 0.75, height: box.height * 0.3 - 4).integral
            // The strip is small, so the accurate model costs little; fast misreads "Priya" as "Prlya".
            if let crop = img.cropping(to: strip) {
                speaker = recognize(crop, level: .accurate).compactMap(cleanName).first
            }
        }
        var names: [String] = []
        if roster {
            for n in recognize(img, level: .fast).compactMap(cleanName) where !names.contains(n) { names.append(n) }
        }
        if let s = speaker { names.removeAll { $0 == s }; names.insert(s, at: 0) }
        return (speaker, names)
    }

    nonisolated static func recognize(_ img: CGImage, level: VNRequestTextRecognitionLevel) -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        req.recognitionLanguages = ["en"]
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: img).perform([req])
        // top-to-bottom, left-to-right (Vision's y is bottom-up)
        return (req.results ?? [])
            .sorted { a, b in
                abs(a.boundingBox.minY - b.boundingBox.minY) > 0.02 ? a.boundingBox.minY > b.boundingBox.minY : a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    private nonisolated static let uiWords: Set<String> = [
        "You", "Present now", "Presentation", "Leave call", "Raise hand", "Chat", "People", "Activities",
        "Meeting details", "Turn on captions", "More options", "Host controls", "Participants", "Mute",
        "Unmute", "Start video", "Stop video", "Share", "Share screen", "Record", "Reactions", "Apps",
        "Leave", "End", "View", "Gallery view", "Speaker view", "Camera", "Mic", "More", "Rooms",
    ]

    /// Pure. A tile label that reads like a person's name, or nil. Strips Meet's " (You)" suffix
    /// and maps it to "You" so it lines up with the mic stream's own label.
    // ponytail: Latin-script names only (OCR runs with `en`); widen recognitionLanguages if Indic names show up as nil.
    nonisolated static func cleanName(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("(You)") || s.hasSuffix("(you)") { return "You" }
        s = s.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
        guard (2...40).contains(s.count), !uiWords.contains(s) else { return nil }
        let words = s.split(separator: " ")
        guard (1...4).contains(words.count) else { return nil }
        for w in words {
            guard let f = w.first, f.isUppercase, w.allSatisfy({ $0.isLetter || ".'-".contains($0) }) else { return nil }
        }
        return s
    }

    /// Pure. Bounding box (top-left pixel coords) of the active-speaker border: rows whose longest run
    /// of border-coloured pixels is long are tile edges; the longest edge sets the x-range, edge rows
    /// over that range set the y-range. nil if no box at least 40 px tall.
    // ponytail: assumes one highlighted tile; a second same-hue element wider than the tile edge would win.
    nonisolated static func highlightBox(_ img: CGImage, hues: ClosedRange<Double>) -> CGRect? {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        func hit(_ i: Int) -> Bool {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            guard mx >= 0.45, d / mx >= 0.35 else { return false }
            var hue: Double
            if mx == r { hue = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { hue = 60 * ((b - r) / d + 2) }
            else { hue = 60 * ((r - g) / d + 4) }
            if hue < 0 { hue += 360 }
            return hues.contains(hue)
        }
        let minRun = max(40, w / 12)
        var runs: [(y: Int, x0: Int, x1: Int)] = []
        for y in 0..<h {
            var best = (0, 0), start = -1
            for x in 0...w {
                if x < w, hit((y * w + x) * 4) { if start < 0 { start = x } }
                else if start >= 0 { if x - start > best.1 - best.0 { best = (start, x) }; start = -1 }
            }
            if best.1 - best.0 >= minRun { runs.append((y, best.0, best.1)) }
        }
        guard let top = runs.max(by: { ($0.x1 - $0.x0) < ($1.x1 - $1.x0) }) else { return nil }
        let span = Double(top.x1 - top.x0)
        let edges = runs.filter { r in
            Double(min(r.x1, top.x1) - max(r.x0, top.x0)) >= 0.8 * span
        }
        guard let y0 = edges.map(\.y).min(), let y1 = edges.map(\.y).max(), y1 - y0 >= 40 else { return nil }
        return CGRect(x: top.x0, y: y0, width: top.x1 - top.x0, height: y1 - y0 + 1)
    }

    // MARK: - fixture + checks

    nonisolated static let fixtureNames = ["Asha Rao", "Ben Ortiz", "Priya Shah", "Rahul Mehta"]
    nonisolated static let fixtureSpeaker = "Priya Shah"

    /// Synthetic Meet frame: 1280x720 dark grid of 4 tiles, white name labels bottom-left, a Meet-blue
    /// border around Priya's tile, and a meeting-code footer the name filter must reject.
    nonisolated static func makeFixture() -> CGImage? {
        let w = 1280, h = 720
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let font = NSFont.systemFont(ofSize: 22, weight: .medium)
        // CG origin is bottom-left: row 0 = top row of tiles.
        for (i, name) in fixtureNames.enumerated() {
            let tile = CGRect(x: 24 + (i % 2) * 624, y: h - 24 - 320 - (i / 2) * 330, width: 608, height: 310)
            ctx.setFillColor(CGColor(red: 0.24, green: 0.25, blue: 0.27, alpha: 1))
            ctx.fill(tile)
            if name == fixtureSpeaker {
                ctx.setStrokeColor(CGColor(red: 26 / 255, green: 115 / 255, blue: 232 / 255, alpha: 1))
                ctx.setLineWidth(6)
                ctx.stroke(tile.insetBy(dx: 3, dy: 3))
            }
            NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.white])
                .draw(at: CGPoint(x: tile.minX + 18, y: tile.minY + 16))
        }
        NSAttributedString(string: "10:42 | abc-defg-hij", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.lightGray])
            .draw(at: CGPoint(x: 24, y: 2))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func selfTest() {
        precondition(cleanName("Asha Rao") == "Asha Rao", "name")
        precondition(cleanName("Charandeep Kapoor (You)") == "You", "meet self label")
        precondition(cleanName("10:42 | abc-defg-hij") == nil, "meeting code rejected")
        precondition(cleanName("Leave call") == nil && cleanName("present now") == nil, "ui text rejected")
        precondition(Kind(meetingID: "us.zoom.xos") == .zoom && Kind(meetingID: "com.microsoft.teams") == .teams
                     && Kind(meetingID: "meet.google.com") == .meet, "kind")
        guard let img = makeFixture(), let box = highlightBox(img, hues: Kind.meet.hues) else { preconditionFailure("fixture box") }
        // Priya is tile 3: bottom-left, x 24..632, top-left y 364..674.
        precondition(abs(box.minX - 24) <= 8 && abs(box.minY - 364) <= 8 && abs(box.width - 608) <= 12 && abs(box.height - 310) <= 12, "box \(box)")
        precondition(highlightBox(img, hues: Kind.zoom.hues) == nil, "no green border")
        print("ScreenSpeakerReader.selfTest PASS")
    }

    /// `--ocr-test <png> [meet|teams|zoom]`: speaker first, then every name found. Exit 1 if no speaker.
    static func runOCRTest(path: String, kind: Kind) -> Int32 {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("error: cannot read \(path)"); return 1 }
        var t0 = Date()
        let r = analyze(img, kind: kind, roster: true)
        let cold = Date().timeIntervalSince(t0) * 1000
        t0 = Date()
        _ = analyze(img, kind: kind, roster: false) // the per-second live path, models warm
        print("speaker: \(r.speaker ?? "none")")
        print("names: \(r.names.joined(separator: ", "))")
        print(String(format: "ms: cold %.0f (with roster), warm frame %.0f", cold, Date().timeIntervalSince(t0) * 1000))
        return r.speaker == nil ? 1 : 0
    }

    /// `--make-ocr-fixture <png>`: writes `makeFixture()` as PNG.
    static func writeFixture(path: String) -> Int32 {
        guard let img = makeFixture(),
              let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]),
              (try? data.write(to: URL(fileURLWithPath: path))) != nil else { print("error: fixture"); return 1 }
        print("wrote \(path)")
        return 0
    }
}
