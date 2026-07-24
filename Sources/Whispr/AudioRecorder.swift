import AVFoundation

enum AudioRecorderError: Error { case converterInitFailed }

/// Captures microphone audio via AVAudioEngine into a shared ResamplingBuffer
/// (16 kHz mono Float32 — the format WhisperKit expects).
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let buffer = ResamplingBuffer()
    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return } // double-start would install a second tap → NSException
        buffer.reset()
        let input = engine.inputNode
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
