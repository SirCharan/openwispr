import Foundation
import FluidAudio

/// On-device speaker diarization (FluidAudio / pyannote CoreML). Splits the meeting's
/// system-audio stream into Speaker A/B/C… Models auto-download on first use (~100MB).
/// Any failure degrades to the plain "Others" label — never blocks a meeting.
actor Diarizer {
    struct Segment {
        let speaker: String   // "Speaker A", "Speaker B", …
        let start: Double
        let end: Double
    }

    private var manager: DiarizerManager?

    /// Download models (idempotent) and initialize. Throws on network/model failure.
    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await DiarizerModels.downloadIfNeeded()
        let m = DiarizerManager()
        m.initialize(models: models)
        manager = m
    }

    /// Diarize a full 16 kHz mono recording into lettered speaker segments.
    func diarize(_ samples: [Float]) throws -> [Segment] {
        guard let manager else { throw DiarizerError.notInitialized }
        let result = try manager.performCompleteDiarization(samples)
        // map raw speaker ids to stable letters in order of first appearance
        var letterFor: [String: String] = [:]
        var next = 0
        let letters = ["A", "B", "C", "D", "E", "F", "G", "H"]
        var out: [Segment] = []
        for seg in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            if letterFor[seg.speakerId] == nil {
                letterFor[seg.speakerId] = letters[min(next, letters.count - 1)]
                next += 1
            }
            out.append(Segment(
                speaker: "Speaker \(letterFor[seg.speakerId]!)",
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds)
            ))
        }
        return out
    }

    /// Pure: pick the speaker whose segments overlap [start,end) the most; nil when nothing overlaps.
    static func assign(start: Double, end: Double, segments: [Segment]) -> String? {
        var overlap: [String: Double] = [:]
        for s in segments {
            let o = min(end, s.end) - max(start, s.start)
            if o > 0 { overlap[s.speaker, default: 0] += o }
        }
        return overlap.max(by: { $0.value < $1.value })?.key
    }

    static func selfTest() {
        let segs = [
            Segment(speaker: "Speaker A", start: 0, end: 10),
            Segment(speaker: "Speaker B", start: 10, end: 20),
        ]
        assert(assign(start: 2, end: 8, segments: segs) == "Speaker A", "assign A failed")
        assert(assign(start: 12, end: 18, segments: segs) == "Speaker B", "assign B failed")
        assert(assign(start: 8, end: 13, segments: segs) == "Speaker B", "max-overlap failed") // 2s A vs 3s B
        assert(assign(start: 25, end: 30, segments: segs) == nil, "no-overlap should be nil")
        print("Diarizer.selfTest PASS")
    }
}
