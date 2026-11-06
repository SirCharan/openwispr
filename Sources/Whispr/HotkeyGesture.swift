import Foundation

/// Pure hold / tap / double-tap decision logic for the dictation trigger. Adapted from Muesli (MIT)
/// HotkeyMonitor.swift timing (350 ms double-tap window, 0.18 s tap guard); see THIRD-PARTY.md.
/// Recording state is passed in (the recorder is the truth), so UI stop/cancel can't desync it.
struct HotkeyGesture {
    enum Action: String { case holdStart, holdEnd, toggle, handsFreeStart, handsFreeStop }

    static let holdThreshold: TimeInterval = 0.5
    static let doubleTapWindow: TimeInterval = 0.35
    static let tapGuard: TimeInterval = 0.18

    var doubleTapEnabled = true
    private var isDown = false
    private var downAt: TimeInterval = 0
    private var lastDownAt: TimeInterval?
    private var lastTapUpAt: TimeInterval?
    private var handsFree = false

    /// A second press shortly after a quick tap keeps the session open until the next tap.
    mutating func down(at t: TimeInterval, isRecording: Bool) -> Action? {
        guard !isDown else { return nil } // key-repeat: a down with no up in between
        if let last = lastDownAt, t - last < Self.tapGuard { return nil } // bounce
        isDown = true; lastDownAt = t; downAt = t
        if !isRecording { handsFree = false; lastTapUpAt = nil; return .holdStart }
        if handsFree { handsFree = false; lastTapUpAt = nil; return .handsFreeStop }
        if doubleTapEnabled, let up = lastTapUpAt, t - up < Self.doubleTapWindow {
            handsFree = true; lastTapUpAt = nil; return .handsFreeStart
        }
        lastTapUpAt = nil
        return .toggle
    }

    mutating func up(at t: TimeInterval, isRecording: Bool) -> Action? {
        guard isDown else { return nil }
        isDown = false
        guard isRecording, !handsFree else { return nil }
        if t - downAt > Self.holdThreshold { lastTapUpAt = nil; return .holdEnd }
        lastTapUpAt = t // quick tap: session stays open
        return nil
    }

    struct Fixture: Decodable {
        struct Sequence: Decodable { let name: String; let doubleTap: Bool; let events: [[String]]; let actions: [String] }
        let sequences: [Sequence]
    }

    static func selfTest() {
        let f = Fixtures.load(Fixture.self, "hotkey_gestures.json")
        Fixtures.expect(f.sequences.count >= 6, "hotkey_gestures.json needs >= 6 sequences")
        for s in f.sequences {
            var g = HotkeyGesture(); g.doubleTapEnabled = s.doubleTap
            var recording = false
            var got: [String] = []
            for e in s.events { // ["down"|"up", seconds]
                let t = Double(e[1])!
                let a = e[0] == "down" ? g.down(at: t, isRecording: recording) : g.up(at: t, isRecording: recording)
                guard let a else { continue }
                got.append(a.rawValue)
                recording = a == .holdStart || a == .handsFreeStart
            }
            Fixtures.expectEqual(got, s.actions, "gesture \(s.name)")
        }
        print("HotkeyGesture.selfTest PASS (\(f.sequences.count) sequences)")
    }
}
