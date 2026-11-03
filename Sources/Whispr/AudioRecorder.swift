import AVFoundation

enum AudioRecorderError: Error { case converterInitFailed }

/// "560227702 ('!dat')" for an OSStatus-bearing error, else its localized description.
func describeOSStatus(_ error: Error) -> String {
    let ns = error as NSError
    let code = ns.code
    let u = UInt32(bitPattern: Int32(truncatingIfNeeded: code))
    let bytes = [UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    let cc = printable ? " ('\(String(decoding: bytes, as: UTF8.self))')" : ""
    return "\(error.localizedDescription) [\(ns.domain) \(code)\(cc)]"
}

/// Captures microphone audio via AVAudioEngine into a shared ResamplingBuffer
/// (16 kHz mono Float32 — the format WhisperKit expects).
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let buffer = ResamplingBuffer()
    private(set) var isRecording = false

    init() { buffer.label = "mic" }

    /// Buffer-arrival counters, for the CLI gates and for diagnosing a dead mic.
    var diagnostics: ResamplingBuffer.Diagnostics { buffer.diagnostics }

    /// `voiceProcessing` enables Apple's AEC (subtracts speaker playback from the mic —
    /// kills meeting echo). Off for plain dictation. Failure is non-fatal: record without it.
    func start(voiceProcessing: Bool = false) throws {
        guard !isRecording else { return } // double-start would install a second tap → NSException
        buffer.reset()
        buffer.releaseConverter() // converter is rebuilt from the first buffer's real format
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
                Log.audio.error("""
                    mic: voice processing (AEC) unavailable, recording without it: \
                    \(describeOSStatus(error), privacy: .public)
                    """)
            }
        }
        // Always the node's CURRENT format (read after the VP toggle), never a cached one.
        let inFormat = input.outputFormat(forBus: 0)
        // A zero sample rate here means the input device is not actually available; the tap
        // would install and never fire, which reads downstream as a silent room.
        Log.audio.info("""
            mic: starting — requestedAEC=\(voiceProcessing, privacy: .public) \
            actualAEC=\(input.isVoiceProcessingEnabled, privacy: .public) \
            format=\(inFormat.sampleRate, privacy: .public)Hz \(inFormat.channelCount, privacy: .public)ch
            """)
        if inFormat.sampleRate == 0 {
            Log.audio.error("mic: input format reports 0 Hz — no usable input device")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [buffer] pcm, _ in
            buffer.append(pcm)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0) // don't leak the tap: the next start() would install a second one
            engine.stop()
            engine.reset()
            buffer.releaseConverter()
            buffer.reset()
            isRecording = false
            throw error
        }
        isRecording = true
    }

    /// Stop capture and return the full 16 kHz mono sample buffer.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset() // drop cached graph formats so a restart negotiates fresh
        buffer.releaseConverter()
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
