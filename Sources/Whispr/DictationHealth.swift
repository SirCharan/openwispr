import CoreAudio
import Foundation

/// Mic-health watchdog for dictation. 3 s after start: no buffers arrived, or the recent audio is
/// flat silence → one warning in the pill. A warning never stops the recording. Also warns when
/// the input device disappears. Adapted from Muesli (MIT) DictationStartupWatchdog.swift and
/// DictationCaptureHealth.swift (much reduced: one timer, no phase tracking).
@MainActor
final class DictationHealth {
    static let warnAfter: TimeInterval = 3
    /// Below this the mic is delivering digital silence (a live room sits well above it).
    static let silentRMS: Float = 0.0005
    static let silentMessage = "Mic is silent — check input device"
    static let goneMessage = "Mic disconnected — recording will fail"

    /// nil = healthy. Pure so `--health-test` and selftest can drive it.
    static func verdict(buffers: Int, tailRMS: Float) -> String? {
        buffers == 0 || tailRMS < silentRMS ? silentMessage : nil
    }

    private var timer: Timer?
    private var listener: (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?
    private(set) var warning: String?

    /// `sample` reads the live recorder; `onWarning` fires at most once per start.
    func start(delay: TimeInterval = DictationHealth.warnAfter,
               sample: @escaping () -> (buffers: Int, tailRMS: Float),
               onWarning: @escaping (String) -> Void) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.warning == nil else { return }
                let s = sample()
                if let w = Self.verdict(buffers: s.buffers, tailRMS: s.tailRMS) { self.fire(w, onWarning) }
            }
        }
        watchDeviceAlive { [weak self] in
            MainActor.assumeIsolated { if let self, self.warning == nil { self.fire(Self.goneMessage, onWarning) } }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let (id, addr, block) = listener {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
        listener = nil
        warning = nil
    }

    private func fire(_ message: String, _ cb: (String) -> Void) {
        warning = message
        Log.audio.error("dictation health: \(message, privacy: .public)")
        cb(message)
    }

    /// Fires `onDead` when CoreAudio reports the default input device is no longer alive.
    private func watchDeviceAlive(_ onDead: @escaping () -> Void) {
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var def = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &def, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return }
        var alive = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            var v: UInt32 = 1
            var sz = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let st = AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v)
            if st != noErr || v == 0 { onDead() }
        }
        if AudioObjectAddPropertyListenerBlock(dev, &alive, DispatchQueue.main, block) == noErr {
            listener = (dev, alive, block)
        }
    }

    /// True when the clip had audible speech (so an empty transcript is a failure, not silence).
    static func hadSpeech(_ samples: [Float]) -> Bool {
        let win = 8000 // 0.5 s
        var i = 0
        while i < samples.count {
            if ResamplingBuffer.rms(samples[i..<min(i + win, samples.count)]) >= Float(Settings.defaultMeetingSpeechFloor) { return true }
            i += win
        }
        return false
    }

    static func selfTest() {
        Fixtures.expect(verdict(buffers: 0, tailRMS: 0.1) != nil, "no buffers warns")
        Fixtures.expect(verdict(buffers: 40, tailRMS: 0) != nil, "silent tail warns")
        Fixtures.expect(verdict(buffers: 40, tailRMS: 0.02) == nil, "live mic is healthy")
        Fixtures.expect(!hadSpeech([Float](repeating: 0.001, count: 32000)), "room tone is not speech")
        Fixtures.expect(hadSpeech([Float](repeating: 0.1, count: 8000)), "loud audio is speech")
        print("DictationHealth.selfTest PASS")
    }

    /// `--health-test`: a silent synthetic source must warn within 3.5 s. Returns the exit code.
    static func runHealthTest() -> Int32 {
        let h = DictationHealth()
        var firedAt: TimeInterval?
        let t0 = Date()
        h.start(sample: { (buffers: 100, tailRMS: 0) }, onWarning: { _ in firedAt = Date().timeIntervalSince(t0) })
        RunLoop.current.run(until: t0.addingTimeInterval(3.5))
        h.stop()
        guard let t = firedAt else { print("health-test FAIL: no warning within 3.5 s"); return 1 }
        print("health-test PASS: warning after \(String(format: "%.2f", t)) s")
        return t >= 2.9 ? 0 : 1
    }
}
