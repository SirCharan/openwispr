import Foundation
import AVFoundation
import QuartzCore
import FluidAudio

/// One meeting-wide monotonic clock: seconds since the meeting started, paused time excluded.
/// Host time (mach, the base of `CACurrentMediaTime` and `AVAudioTime.hostTime`) at start is the
/// origin; both streams convert their buffer arrival times through it, so a dropout shows up as a
/// gap on the timeline instead of being compressed out of it.
final class MeetingClock: @unchecked Sendable {
    private let origin = CACurrentMediaTime()
    private var pausedTotal = 0.0
    private var pausedAt: Double?
    private let lock = NSLock()

    func time(forHost host: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        return host - origin - pausedTotal
    }

    func pause() { lock.lock(); pausedAt = CACurrentMediaTime(); lock.unlock() }
    func resume() {
        lock.lock()
        if let p = pausedAt { pausedTotal += CACurrentMediaTime() - p }
        pausedAt = nil
        lock.unlock()
    }
}

/// Cuts one stream into speech segments with FluidAudio's Silero VAD (config and rationale:
/// vault note openwispr-meeting-vad-decision). Samples are fed in arrival order with their
/// meeting-clock start time; segments come back stamped on that same clock.
/// If the VAD model is unavailable it falls back to fixed 15 s segments with 1 s overlap and
/// no silence gate — that can worsen boundaries but can never invent a blank gap.
final class MeetingSegmenter {
    struct Segment { let samples: [Float]; let start: Double }

    static let config = VadSegmentationConfig(
        minSpeechDuration: 0.2, minSilenceDuration: 0.6, maxSpeechDuration: 20.0,
        speechPadding: 0.2, silenceThresholdForSplit: 0.3,
        negativeThreshold: 0.25, negativeThresholdOffset: 0.20)
    private static let rate = 16000
    private static let chunk = VadManager.chunkSize        // 4096, the only size Silero accepts
    private static let maxSpeech = 20 * rate               // not enforced by the state machine
    private static let fallbackSeg = 15 * rate
    private static let fallbackOverlap = rate

    private let vad: VadManager?
    private var state = VadStreamState.initial()
    private var buf: [Float] = []
    private var bufBase = 0          // absolute sample index of buf[0]
    private var processed = 0        // absolute index of the next sample VAD has not seen
    private var segStart: Int?       // absolute start of the speech run in progress
    private var emitted = 0          // fallback only: absolute end of the last emitted segment
    private var t0: Double?          // meeting-clock seconds of absolute sample 0

    init(vad: VadManager?) { self.vad = vad }

    /// Load the Silero model once; nil on failure (caller logs) so segmentation falls back.
    static func loadVad() async -> VadManager? {
        do { return try await VadManager() }
        catch {
            Log.audio.error("silero VAD unavailable, using fixed 15s segments: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func slice(_ a: Int, _ b: Int) -> Segment? {
        let lo = max(a, bufBase), hi = min(b, bufBase + buf.count)
        guard hi > lo, let t0 else { return nil }
        return Segment(samples: Array(buf[(lo - bufBase)..<(hi - bufBase)]), start: t0 + Double(lo) / Double(Self.rate))
    }

    func feed(_ samples: [Float], start: Double) async -> [Segment] {
        if t0 == nil { t0 = start - Double(bufBase + buf.count) / Double(Self.rate) }
        buf.append(contentsOf: samples)
        var out: [Segment] = []
        guard let vad else { return fallback() }
        while bufBase + buf.count - processed >= Self.chunk {
            let lo = processed - bufBase
            let frame = Array(buf[lo..<(lo + Self.chunk)])
            do {
                let r = try await vad.processStreamingChunk(frame, state: state, config: Self.config)
                state = r.state
                if let e = r.event {
                    switch e.kind {
                    case .speechStart: segStart = max(e.sampleIndex, bufBase)
                    case .speechEnd:
                        if let s = segStart, let seg = slice(s, max(e.sampleIndex, s)) { out.append(seg) }
                        segStart = nil
                    }
                }
            } catch {
                // Never lose audio to a VAD error: treat the frame as speech.
                Log.audio.error("silero VAD failed on a frame, keeping it: \(error.localizedDescription, privacy: .public)")
                if segStart == nil { segStart = processed }
                state = VadStreamState(modelState: state.modelState, triggered: true,
                                       tempEndSample: nil, processedSamples: state.processedSamples + Self.chunk)
            }
            processed += Self.chunk
            if let s = segStart, processed - s >= Self.maxSpeech {
                if let seg = slice(s, processed) { out.append(seg) }
                segStart = processed
            }
            // A speechStart points back by the padding, so keep that much behind the cursor.
            let keep = min(segStart ?? processed, processed - Self.chunk - Self.rate / 4)
            if keep > bufBase { buf.removeFirst(keep - bufBase); bufBase = keep }
        }
        return out
    }

    /// Fixed segments, 1 s overlap, no gate. Emits whenever 15 s of fresh audio has accumulated.
    private func fallback() -> [Segment] {
        var out: [Segment] = []
        while bufBase + buf.count - emitted >= Self.fallbackSeg {
            let from = max(bufBase, emitted - Self.fallbackOverlap)
            if let seg = slice(from, from + Self.fallbackSeg) { out.append(seg) }
            emitted = from + Self.fallbackSeg
            let keep = emitted - Self.fallbackOverlap
            if keep > bufBase { buf.removeFirst(keep - bufBase); bufBase = keep }
        }
        return out
    }

    /// Pause/stop: hand back whatever speech is still open, then forget the stream.
    func flush() -> [Segment] {
        var out: [Segment] = []
        let end = bufBase + buf.count
        if vad == nil {
            if end - emitted > Self.rate / 2, let seg = slice(max(bufBase, emitted - Self.fallbackOverlap), end) { out.append(seg) }
        } else if let s = segStart, let seg = slice(s, end) {
            out.append(seg)
        }
        state = .initial(); buf.removeAll(); bufBase = 0; processed = 0; emitted = 0; segStart = nil; t0 = nil
        return out
    }

    /// Fallback path only (no model needed), so `--selftest` stays offline.
    static func selfTest() async {
        let seg = MeetingSegmenter(vad: nil)
        let r = Self.rate
        var got = await seg.feed([Float](repeating: 0.1, count: 20 * r), start: 100)
        Fixtures.expect(got.count == 1 && got[0].samples.count == 15 * r && got[0].start == 100, "fallback first segment")
        got = await seg.feed([Float](repeating: 0.1, count: 20 * r), start: 120)
        Fixtures.expect(got.count == 1 && abs(got[0].start - 114) < 0.001, "fallback overlap start \(got.map(\.start))")
        let tail = seg.flush()
        Fixtures.expect(tail.count == 1 && abs((tail[0].start + Double(tail[0].samples.count) / 16000) - 140) < 0.001, "fallback flush ends at 140")
        print("MeetingSegmenter.selfTest PASS")
    }
}
