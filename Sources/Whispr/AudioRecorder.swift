import AVFoundation

enum AudioRecorderError: Error { case converterInitFailed }

/// Captures microphone audio via AVAudioEngine into a shared ResamplingBuffer
/// (16 kHz mono Float32 — the format WhisperKit expects).
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let buffer = ResamplingBuffer()
    private(set) var isRecording = false

    /// `voiceProcessing` enables Apple's AEC (subtracts speaker playback from the mic —
    /// kills meeting echo). Off for plain dictation. Failure is non-fatal: record without it.
    func start(voiceProcessing: Bool = false) throws {
        guard !isRecording else { return } // double-start would install a second tap → NSException
        buffer.reset()
        let input = engine.inputNode
        if voiceProcessing != input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(voiceProcessing)
                if voiceProcessing, #available(macOS 14.0, *) {
                    // don't duck the meeting audio we're transcribing
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                            enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch {
                NSLog("[Whispr] voice processing unavailable, recording without AEC: \(error)")
            }
        }
        let inFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [buffer] pcm, _ in
            buffer.append(pcm)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stop capture and return the full 16 kHz mono sample buffer.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return buffer.snapshot()
    }

    /// Non-destructive copy of the buffer tail (for live preview). `last` nil = everything.
    func snapshot(last seconds: Double? = nil) -> [Float] { buffer.snapshot(last: seconds) }

    /// Take buffered samples and clear (live chunked transcription).
    func drain() -> [Float] { buffer.drain() }

    var bufferedSeconds: Double { buffer.bufferedSeconds }
    func tailRMS(_ seconds: Double) -> Float { buffer.tailRMS(seconds) }
}
