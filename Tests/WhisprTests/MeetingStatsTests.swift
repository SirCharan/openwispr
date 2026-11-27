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

    func testRealisticSessionGapsBlipsAndQuestions() {
        let m = MeetingStats.realisticFixture()
        let you = m.speakers.first { $0.name == "You" }!
        XCTAssertEqual(you.longestMonologue, 20, accuracy: 0.001) // the 40-minute gap does not inflate it
        XCTAssertEqual(you.turns, 3)
        XCTAssertEqual(m.speakers.first { $0.name == "A" }!.turns, 3)
        XCTAssertEqual(m.recorded, 2900, accuracy: 0.001)
        XCTAssertEqual(m.active ?? 0, 96, accuracy: 0.001)
        XCTAssertGreaterThan(m.speakers.first { $0.name == "Others" }!.sharePct, 0)
        XCTAssertLessThan(you.sharePct, 100)
        XCTAssertEqual(m.questionsPerHour, 2 / (96.0 / 3600), accuracy: 0.001) // two questions in one line
        XCTAssertEqual(m.interruptionsPerHour, Double(m.interruptions) / (96.0 / 3600), accuracy: 0.001)
    }

    func testQuestionCountAndFillers() {
        XCTAssertEqual(MeetingStats.questionCount("Why? And how? Fine."), 2)
        XCTAssertEqual(MeetingStats.questionCount("see a.com/x?y=1 ok"), 0)
        XCTAssertEqual(MeetingStats.questionCount("Really?!"), 1)
        let m = MeetingStats.compute(segments: [seg("A", 0, 60)], lines: [line("A", "so right okay like", 0, 60)])
        XCTAssertEqual(m.fillersPerMinute, 0, accuracy: 0.001)
    }

    func testOldStatsJSONDecodes() throws {
        let json = #"{"questionsPerHour":1,"duration":100,"fillersPerMinute":2,"speakers":[],"you":"You","date":"2026-01-01T00:00:00Z"}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let m = try dec.decode(MeetingStats.self, from: Data(json.utf8))
        XCTAssertNil(m.active)
        XCTAssertEqual(m.activeOrRecorded, 100)
    }
}

final class MeetingCaptureHealthTests: XCTestCase {
    func testMicWatchdogIgnoresQuietRoomButCatchesDigitalSilence() {
        func fires(_ rms: Float) -> Int {
            var w = MicDeadWatchdog()
            return (0..<48).filter { _ in w.observe(rms: rms, seconds: 0.25) }.count
        }
        XCTAssertEqual(fires(0.0), 1)
        XCTAssertEqual(fires(0.0003), 0)
        XCTAssertEqual(fires(0.08), 0)
    }

    func testOthersSilenceNeedsMicSpeechAndClears() {
        var w = OthersSilenceWatchdog()
        XCTAssertFalse(w.observeOthers(rms: 0, seconds: 600))
        w.observeMic(rms: 0.05)
        XCTAssertTrue(w.observeOthers(rms: 0, seconds: 1))
        XCTAssertFalse(w.observeOthers(rms: 0.01, seconds: 1))
        XCTAssertFalse(w.observeOthers(rms: 0, seconds: 299))
    }

    func testBannersCoexistAndClearIndependently() {
        var b = BannerSet()
        b.set(.systemLost, true); b.set(.micLost, true); b.set(.noCallAudio, true)
        XCTAssertEqual(b.lines.count, 3)
        b.set(.micLost, false)
        XCTAssertEqual(b.lines, ["System audio lost, recording mic only", "No audio from the call is being captured"])
    }

    func testBackoffScheduleAndLogRateLimit() {
        XCTAssertEqual((1...8).map { MeetingController.sysBackoff(attempt: $0) }, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(MeetingController.sysBackoff(attempt: 1_000_000), 30)
        XCTAssertTrue(MeetingController.shouldLogSysFailure(attempt: 3))
        XCTAssertFalse(MeetingController.shouldLogSysFailure(attempt: 4))
        XCTAssertTrue(MeetingController.shouldLogSysFailure(attempt: 20))
    }
}

final class LicenseGateTests: XCTestCase {
    func testSourceBuildMarkerAllowsUnlicensed() {
        XCTAssertTrue(License.allows(.meet, in: .unlicensed, info: ["OWSourceBuild": true]))
    }
    func testMissingOrFalseMarkerEnforces() {
        XCTAssertFalse(License.allows(.dictate, in: .unlicensed, info: nil))
        XCTAssertFalse(License.allows(.dictate, in: .unlicensed, info: ["OWSourceBuild": false]))
        XCTAssertTrue(License.allows(.dictate, in: .active, info: nil))
    }
}
