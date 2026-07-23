import AppKit

@main
enum Whispr {
    static func main() {
        let args = CommandLine.arguments

        // --- headless gates (loop engineering) ---
        if args.contains("--selftest") {
            WavEncoder.selfTest()
            exit(0)
        }
        if let i = args.firstIndex(of: "--record-test"), i + 2 < args.count {
            let seconds = Double(args[i + 1]) ?? 3
            let path = args[i + 2]
            runRecordTest(seconds: seconds, path: path)
            exit(0)
        }

        // --- normal menu-bar app ---
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // menu-bar-only; pairs with LSUIElement
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
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AppController()
        controller?.start()
    }
}
