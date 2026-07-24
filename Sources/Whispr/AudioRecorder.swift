import AVFoundation

enum AudioRecorderError: Error { case converterInitFailed, bufferAllocFailed }

/// Captures microphone audio via AVAudioEngine and resamples to 16 kHz mono Float32
/// (the format WhisperKit expects). Start on hotkey-down, stop on hotkey-up.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }

    func start() throws {
        guard !isRecording else { return } // double-start would install a second tap → NSException
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inFormat, to: targetFormat) else {
            throw AudioRecorderError.converterInitFailed
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            self?.append(buf)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Drain samples captured so far without stopping (for live chunked transcription).
    func drain() -> [Float] {
        lock.lock(); let out = samples; samples.removeAll(keepingCapacity: true); lock.unlock()
        return out
    }

    /// Non-destructive copy of the buffer tail (for live preview). `last` nil = everything.
    func snapshot(last seconds: Double? = nil) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard let seconds else { return samples }
        let n = min(samples.count, Int(seconds * 16000))
        return Array(samples.suffix(n))
    }

    /// Seconds of audio currently buffered (since last drain).
    var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16000
    }

    /// RMS of the trailing `seconds` of the buffer — low value = the speaker paused.
    func tailRMS(_ seconds: Double) -> Float {
        lock.lock(); defer { lock.unlock() }
        let n = min(samples.count, Int(seconds * 16000))
        guard n > 0 else { return 0 }
        let tail = samples.suffix(n)
        return sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(n))
    }

    /// Stop capture and return the full 16 kHz mono sample buffer.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); let out = samples; lock.unlock()
        return out
    }

    private func append(_ pcm: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        guard error == nil, let ch = out.floatChannelData else { return }
        let n = Int(out.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
        lock.unlock()
    }
}
