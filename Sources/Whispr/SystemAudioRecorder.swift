import ScreenCaptureKit
import AVFoundation

enum SystemAudioError: Error { case noDisplay }

/// Captures system-output audio (the "Others" side of a meeting) via ScreenCaptureKit
/// into a shared ResamplingBuffer. Requires the Screen Recording TCC permission
/// (audio ride-along; video frames are discarded).
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let buffer = ResamplingBuffer()
    private(set) var isRecording = false
    /// Fired if the OS tears the stream down mid-meeting (permission revoked, display change).
    /// Lets MeetingController surface it instead of silently freezing "Others".
    var onUnexpectedStop: (@Sendable () -> Void)?

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
        buffer.reset()
        isRecording = true
    }

    /// Stop and return all captured 16 kHz mono samples.
    func stop() async -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        try? await stream?.stopCapture()
        stream = nil
        return buffer.snapshot()
    }

    /// Take buffered samples and clear (live chunked transcription).
    func drain() -> [Float] { buffer.drain() }

    var bufferedSeconds: Double { buffer.bufferedSeconds }
    func tailRMS(_ seconds: Double) -> Float { buffer.tailRMS(seconds) }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        buffer.append(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Whispr] system-audio stream stopped: \(error)")
        let wasRecording = isRecording
        isRecording = false
        if wasRecording { onUnexpectedStop?() } // only if it died mid-capture, not on normal stop()
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
}
