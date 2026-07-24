import AVFoundation

/// Thread-safe sample buffer that resamples incoming PCM to 16 kHz mono Float32
/// (Whisper's input format). Shared by the mic and system-audio recorders — the
/// converter feed dance lives in exactly one place.
final class ResamplingBuffer {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    func reset() {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
    }

    /// Convert and append one PCM buffer (any input format; converter renews on format change).
    func append(_ pcm: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: Self.targetFormat)
        }
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

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

    /// All samples so far, leaving the buffer intact.
    func snapshot(last seconds: Double? = nil) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard let seconds else { return samples }
        let n = min(samples.count, Int(seconds * 16000))
        return Array(samples.suffix(n))
    }

    /// Take everything and clear (for chunked live transcription).
    func drain() -> [Float] {
        lock.lock(); let out = samples; samples.removeAll(keepingCapacity: true); lock.unlock()
        return out
    }

    var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16000
    }

    /// RMS of the trailing `seconds` — low value = the speaker paused.
    func tailRMS(_ seconds: Double) -> Float {
        lock.lock(); defer { lock.unlock() }
        let n = min(samples.count, Int(seconds * 16000))
        guard n > 0 else { return 0 }
        let tail = samples.suffix(n)
        return sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(n))
    }
}
