import XCTest
@testable import Whispr

final class MeetingStatsTests: XCTestCase {
    private func seg(_ s: String, _ a: Double, _ b: Double) -> Diarizer.Segment { .init(speaker: s, start: a, end: b) }
    private func line(_ s: String, _ t: String, _ a: Double, _ b: Double) -> MeetingLine { MeetingLine(speaker: s, text: t, start: a, end: b) }

    func testTalkShareSumsTo100() {
        let m = MeetingStats.compute(segments: [seg("A", 0, 30), seg("B", 30, 50), seg("C", 50, 60)], lines: [])
        XCTAssertEqual(m.speakers.map(\.sharePct).reduce(0, +), 100, accuracy: 0.001)
        XCTAssertEqual(m.speakers.first?.name, "A")
    }

    func testLongestMonologueMergesSegments() {
        let m = MeetingStats.compute(segments: [seg("A", 0, 50), seg("A", 50, 100), seg("B", 100, 110), seg("A", 110, 120)], lines: [])
        let a = m.speakers.first { $0.name == "A" }!
        XCTAssertEqual(a.longestMonologue, 100, accuracy: 0.001)
        XCTAssertTrue(a.longMonologue)
        XCTAssertEqual(a.turns, 2)
    }

    func testInterruptionCountedOnce() {
        // B starts at 5 while A (0-10) and C (2-12) are open: one interruption for B, not two.
        let m = MeetingStats.compute(segments: [seg("A", 0, 10), seg("C", 2, 12), seg("B", 5, 8)], lines: [])
        XCTAssertEqual(m.speakers.first { $0.name == "B" }!.interruptions, 1)
        XCTAssertEqual(m.speakers.first { $0.name == "A" }!.interruptions, 0)
    }

    func testQuestionsPerHourAndHindi() {
        let lines = [line("A", "Kya haal hai?", 0, 60), line("B", "क्या आप ठीक हैं?", 60, 120), line("A", "Fine, you know, fine fine.", 120, 1800)]
        let m = MeetingStats.compute(segments: [seg("A", 0, 60), seg("B", 60, 120), seg("A", 120, 1800)], lines: lines)
        XCTAssertEqual(m.questionsPerHour, 2 / 0.5, accuracy: 0.001) // 2 questions in 1800 s
        XCTAssertGreaterThan(m.fillersPerMinute, 0)
    }
}
