import Foundation
import Testing
@testable import MeetingVox

/// The pure mapping from session time to each track's
/// position, the duration, the line click and the current line.
@Suite("PlaybackTimeline")
struct PlaybackTimelineTests {
    private func info(_ id: PlaybackTrackID, offsetMs: Int = 0, length: TimeInterval = 10) -> PlaybackTrackInfo {
        PlaybackTrackInfo(id: id, url: URL(fileURLWithPath: "/tmp/\(id.rawValue).caf"), offsetMs: offsetMs, length: length)
    }

    @Test func aTrackPositionIsSessionTimeMinusItsOffset() {
        let timeline = PlaybackTimeline(tracks: [info(.mic), info(.system, offsetMs: 1200)])
        #expect(timeline.placement(of: .mic, at: 5.0) == .playing(position: 5.0))
        guard case .playing(let position) = timeline.placement(of: .system, at: 5.0) else {
            Issue.record("system should be playing"); return
        }
        #expect(abs(position - 3.8) < 1e-9)
    }

    @Test func aTrackThatHasNotStartedWaitsWithoutANegativePosition() {
        let timeline = PlaybackTimeline(tracks: [info(.mic), info(.system, offsetMs: 1200)])
        guard case .waiting(let delay) = timeline.placement(of: .system, at: 0.5) else {
            Issue.record("system should wait"); return
        }
        #expect(abs(delay - 0.7) < 1e-9)
        #expect(timeline.placement(of: .system, at: 1.2) == .playing(position: 0))
    }

    @Test func aTrackPastItsEndIsFinished() {
        let timeline = PlaybackTimeline(tracks: [info(.mic, length: 4)])
        #expect(timeline.placement(of: .mic, at: 4.0) == .finished)
        #expect(timeline.placement(of: .mic, at: 9.0) == .finished)
        #expect(timeline.placement(of: .mic, at: 3.99) == .playing(position: 3.99))
    }

    @Test func aTrackOfUnknownLengthNeverFinishes() {
        let timeline = PlaybackTimeline(tracks: [info(.mic, length: 0)])
        #expect(timeline.placement(of: .mic, at: 500) == .playing(position: 500))
    }

    @Test func aMissingTrackHasNoPlacement() {
        let timeline = PlaybackTimeline(tracks: [info(.mic)])
        #expect(timeline.placement(of: .system, at: 1) == nil)
    }

    @Test func durationIsTheLatestEnd() {
        let timeline = PlaybackTimeline(tracks: [info(.mic, length: 10), info(.system, offsetMs: 1200, length: 10)])
        #expect(abs(timeline.duration - 11.2) < 1e-9)
    }

    @Test func oneTrackAndNoTrackTimelines() {
        let one = PlaybackTimeline(tracks: [info(.mic, offsetMs: 500, length: 3)])
        #expect(one.isPlayable)
        #expect(abs(one.duration - 3.5) < 1e-9)
        #expect(one.has(.mic))
        #expect(!one.has(.system))
        let none = PlaybackTimeline(tracks: [])
        #expect(!none.isPlayable)
        #expect(none.duration == 0)
    }

    @Test func aNegativeOffsetIsTreatedAsZero() {
        let timeline = PlaybackTimeline(tracks: [info(.mic, offsetMs: -300)])
        #expect(timeline.placement(of: .mic, at: 2) == .playing(position: 2))
    }

    @Test func clampKeepsTimeInsideTheSession() {
        let timeline = PlaybackTimeline(tracks: [info(.mic, length: 10)])
        #expect(timeline.clamped(-3) == 0)
        #expect(timeline.clamped(4) == 4)
        #expect(timeline.clamped(99) == 10)
    }

    // MARK: - Lines

    @Test func aLineClickSeeksHalfASecondBeforeItsStartClampedAtZero() {
        #expect(PlaybackTimeline.seekTime(forLineStartMs: 300) == 0)
        #expect(PlaybackTimeline.seekTime(forLineStartMs: 10_000) == 9.5)
        #expect(PlaybackTimeline.seekTime(forLineStartMs: 500) == 0)
    }

    private func lines(_ starts: [Int]) -> [TranscriptViewLine] {
        starts.enumerated().map { TranscriptViewLine(id: $0.offset, startMs: $0.element, speaker: "me", text: "x") }
    }

    @Test func theCurrentLineIsTheLastOneStartedAtOrBeforeT() {
        let all = lines([0, 4_000, 9_000, 15_000])
        #expect(PlaybackTimeline.currentLine(in: all, at: 0) == 0)
        #expect(PlaybackTimeline.currentLine(in: all, at: 3.99) == 0)
        #expect(PlaybackTimeline.currentLine(in: all, at: 4.0) == 1)
        #expect(PlaybackTimeline.currentLine(in: all, at: 12) == 2)
        #expect(PlaybackTimeline.currentLine(in: all, at: 500) == 3)
    }

    @Test func beforeTheFirstLineThereIsNoCurrentLine() {
        let all = lines([2_000, 5_000])
        #expect(PlaybackTimeline.currentLine(in: all, at: 1.0) == nil)
        #expect(PlaybackTimeline.currentLine(in: [], at: 3) == nil)
    }
}
