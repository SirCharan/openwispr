import ScreenCaptureKit
import AVFoundation

enum SystemAudioError: Error { case noDisplay, converterInitFailed }

/// Captures system-output audio (the "Others" side of a meeting) via ScreenCaptureKit
/// and resamples to 16 kHz mono Float32 — the same shape AudioRecorder produces for the mic.
/// Requires the Screen Recording TCC permission (audio ride-along; video frames are discarded).
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // minimal video so the stream runs; frames are ignored
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "whispr.sysaudio"))
        try await stream.startCapture()
        self.stream = stream
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        isRecording = true
    }

    /// Stop and return all captured 16 kHz mono samples.
    func stop() async -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        try? await stream?.stopCapture()
        stream = nil
        lock.lock(); let out = samples; lock.unlock()
        return out
    }

    /// Drain samples captured so far (for live chunked transcription).
    func drain() -> [Float] {
        lock.lock(); let out = samples; samples.removeAll(keepingCapacity: true); lock.unlock()
        return out
    }

    /// Seconds of audio currently buffered (since last drain).
    var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16000
    }

    /// RMS of the trailing `seconds` of the buffer — low value = remote side paused.
    func tailRMS(_ seconds: Double) -> Float {
        lock.lock(); defer { lock.unlock() }
        let n = min(samples.count, Int(seconds * 16000))
        guard n > 0 else { return 0 }
        let tail = samples.suffix(n)
        return sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(n))
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        append(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Whispr] system-audio stream stopped: \(error)")
        isRecording = false
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList
        )
        return status == noErr ? buf : nil
    }

    private func append(_ pcm: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: targetFormat)
        }
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
