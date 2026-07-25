import AppKit

@main
enum Whispr {
    static func main() {
        let args = CommandLine.arguments

        // --- headless gates (loop engineering) ---
        if args.contains("--selftest") {
            WavEncoder.selfTest()
            TextProcessor.selfTest()
            DictionaryStore.selfTest()
            SnippetStore.selfTest()
            Stats.selfTest()
            Transliterate.selfTest()
            Task { @MainActor in
                CorrectionsWatcher.selfTest()
                exit(0)
            }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--record-test"), i + 2 < args.count {
            let seconds = Double(args[i + 1]) ?? 3
            let path = args[i + 2]
            runRecordTest(seconds: seconds, path: path)
            exit(0)
        }
        if let i = args.firstIndex(of: "--transcribe-file"), i + 1 < args.count {
            runTranscribeFile(path: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--sysaudio-test"), i + 1 < args.count {
            runSysAudioTest(seconds: Double(args[i + 1]) ?? 5)
            exit(0)
        }
        if let i = args.firstIndex(of: "--concurrency-test"), i + 1 < args.count {
            runConcurrencyTest(path: args[i + 1])
            exit(0)
        }

        // --- single-instance guard: two copies = two fn monitors = every transcript pasted twice ---
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let myID = Bundle.main.bundleIdentifier {
            let twins = NSRunningApplication.runningApplications(withBundleIdentifier: myID)
                .filter { $0.processIdentifier != myPID }
            if let existing = twins.first {
                existing.activate() // hand focus to the copy already running, then bow out
                exit(0)
            }
        }
        // terminate any legacy Whispr-era instance (old bundle id) — same double-paste hazard
        for legacy in NSRunningApplication.runningApplications(withBundleIdentifier: "com.ck.whispr") {
            legacy.terminate()
        }

        // --- normal menu-bar app ---
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // menu-bar-only; pairs with LSUIElement
        Theme.apply()
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// Record `seconds` from the mic, write a WAV to `path`, print sample count + RMS.
    /// Proves the AVAudioEngine → 16 kHz pipeline without the hotkey/GUI.
    private static func runRecordTest(seconds: Double, path: String) {
        let rec = AudioRecorder()
        do {
            try rec.start()
        } catch {
            print("record-test FAIL: \(error)")
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let samples = rec.stop()
        let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let wav = WavEncoder.encode(samples)
        try? wav.write(to: URL(fileURLWithPath: path))
        print("record-test: samples=\(samples.count) (~\(String(format: "%.1f", Double(samples.count) / 16000))s) rms=\(String(format: "%.4f", rms)) wrote=\(path)")
    }

    /// Capture system audio for N seconds and report sample count + RMS.
    /// Proves the ScreenCaptureKit tap without the GUI. Requires Screen Recording permission.
    private static func runSysAudioTest(seconds: Double) {
        Task { @MainActor in
            let rec = SystemAudioRecorder()
            do {
                try await rec.start()
            } catch {
                print("sysaudio-test FAIL: \(error)")
                exit(1)
            }
            try? await Task.sleep(for: .seconds(seconds))
            let samples = await rec.stop()
            let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
            print("sysaudio-test: samples=\(samples.count) (~\(String(format: "%.1f", Double(samples.count) / 16000))s) rms=\(String(format: "%.4f", rms))")
            exit(0)
        }
        dispatchMain()
    }

    /// Two overlapping transcriptions through ONE Transcriber — proves actor serialization
    /// (pre-actor this was the crash/garble class the audit flagged).
    private static func runConcurrencyTest(path: String) {
        Task { @MainActor in
            let mm = ModelManager()
            let t = Transcriber()
            do {
                let folder = try await mm.ensureDownloaded(mm.selectedModel) { _ in }
                try await t.load(model: mm.selectedModel, folder: folder)
                async let a = t.transcribeFile(path)
                async let b = t.transcribeFile(path)
                let (ra, rb) = try await (a, b)
                let ok = !ra.isEmpty && ra == rb
                print(ok ? "concurrency-test PASS: \"\(ra)\"" : "concurrency-test FAIL: \"\(ra)\" vs \"\(rb)\"")
            } catch {
                print("concurrency-test FAIL: \(error)")
            }
            exit(0)
        }
        dispatchMain()
    }

    /// Load the selected model (cached) and transcribe an audio file. Proves the full ASR path.
    /// Drives the main queue via `dispatchMain()` so the @MainActor work runs (never block main with a semaphore).
    private static func runTranscribeFile(path: String) {
        Task { @MainActor in
            let mm = ModelManager()
            let model = mm.selectedModel
            let transcriber = Transcriber()
            do {
                let folder = try await mm.ensureDownloaded(model) { _ in }
                try await transcriber.load(model: model, folder: folder)
                var text = try await transcriber.transcribeFile(path, language: Settings.languageCode)
                if Settings.outputMode == "roman" { text = Transliterate.toLatin(text) }
                print("transcribe-file: \"\(text)\"")
            } catch {
                print("transcribe-file FAIL: \(error)")
            }
            exit(0)
        }
        dispatchMain()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AppController()
        controller?.start()
    }
}
