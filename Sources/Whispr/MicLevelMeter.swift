import AVFoundation

/// Live microphone level for the onboarding "does the mic work?" step.
/// Own AVAudioEngine (independent of AudioRecorder) → publishes a smoothed 0…1 level.
@MainActor
final class MicLevelMeter: ObservableObject {
    @Published var level: Double = 0
    private let engine = AVAudioEngine()
    private var running = false

    func start() {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] pcm, _ in
            guard let ch = pcm.floatChannelData?[0] else { return }
            let n = Int(pcm.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            // map RMS (~0…0.3 for speech) to 0…1, smoothed
            let scaled = min(1, Double(rms) * 12)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.level = self.level * 0.6 + scaled * 0.4
            }
        }
        engine.prepare()
        do { try engine.start(); running = true }
        catch { NSLog("[Whispr] mic meter start failed: \(error)") }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        level = 0
    }
}
