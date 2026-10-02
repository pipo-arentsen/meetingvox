import Foundation
import Testing
@testable import MeetingVox

/// The controller over fake tracks, a manual ticker
/// and a shared fake device clock. No audio device is touched.
@MainActor
@Suite final class PlaybackControllerTests {
    let clock = FakeDeviceClock()
    let log = FakeLog()
    let ticker = ManualTicker()
    var tracks: [PlaybackTrackID: FakePlayerTrack] = [:]
    var recording: (dir: URL?, excludesSelf: Bool) = (nil, false)
    var failing: Set<PlaybackTrackID> = []
    var prepareFails = false
    let a = URL(fileURLWithPath: "/rec/2026.09.30-1000")
    let b = URL(fileURLWithPath: "/rec/2026.09.30-1100")

    func info(_ id: PlaybackTrackID, offsetMs: Int = 0, length: TimeInterval = 20) -> PlaybackTrackInfo {
        PlaybackTrackInfo(id: id, url: URL(fileURLWithPath: "/rec/\(id.rawValue).caf"), offsetMs: offsetMs, length: length)
    }

    var both: [PlaybackTrackInfo] { [info(.mic), info(.system, offsetMs: 1200)] }

    /// Players are fake: their own duration is what `AVAudioPlayer.duration` would say.
    func controller(playerDuration: TimeInterval = 20) -> PlaybackController {
        PlaybackController(
            makeTrack: { [unowned self] info in
                guard !failing.contains(info.id) else { return nil }
                let track = FakePlayerTrack(name: info.id.rawValue, duration: playerDuration, clock: clock, log: log)
                track.prepareResult = !prepareFails
                tracks[info.id] = track
                return track
            },
            ticker: ticker,
            recordingState: { [unowned self] in recording }
        )
    }

    func shown(_ tracks: [PlaybackTrackInfo]? = nil, lines: [TranscriptViewLine] = [], playerDuration: TimeInterval = 20) -> PlaybackController {
        let c = controller(playerDuration: playerDuration)
        c.show(dir: a, tracks: tracks ?? both, lines: lines)
        return c
    }

    // MARK: - Starting

    @Test func bothTracksStartOnOneDeviceClock() {
        let c = shown()
        c.play()
        let base = clock.now + PlaybackController.startLead
        #expect(tracks[.mic]?.scheduledStart == base)
        // system begins 1.2 s into the session: same clock, later start.
        #expect(abs((tracks[.system]?.scheduledStart ?? 0) - (base + 1.2)) < 1e-9)
        #expect(c.isPlaying)
        #expect(ticker.isRunning)
    }

    @Test func playingFromAPositionPlacesEachTrackOnItsOwnTime() {
        let c = shown()
        c.seek(to: 5.0)
        c.play()
        #expect(tracks[.mic]?.setPositions.last == 5.0)
        #expect(abs((tracks[.system]?.setPositions.last ?? 0) - 3.8) < 1e-9)
        #expect(tracks[.mic]?.scheduledStart == tracks[.system]?.scheduledStart)
    }

    @Test func aTrackThatHasNotStartedWaitsAndIsRewoundToItsStart() {
        let c = shown()
        c.seek(to: 0.5)
        c.play()
        #expect(tracks[.system]?.setPositions.last == 0)
        let base = clock.now + PlaybackController.startLead
        #expect(abs((tracks[.system]?.scheduledStart ?? 0) - (base + 0.7)) < 1e-9)
    }

    @Test func aWaitingTrackDelayIsInDeviceSecondsSoItShrinksWithRate() {
        let c = shown()
        c.rate = 2
        c.play()
        let base = clock.now + PlaybackController.startLead
        #expect(abs((tracks[.system]?.scheduledStart ?? 0) - (base + 0.6)) < 1e-9)
    }

    @Test func enableRateIsSetBeforePrepareToPlay() {
        let c = shown()
        c.play()
        #expect(log.events.contains("mic.prepare(enableRate: true)"))
        #expect(log.events.contains("system.prepare(enableRate: true)"))
        let enable = log.events.firstIndex(of: "mic.enableRate=true")
        let prepare = log.events.firstIndex(of: "mic.prepare(enableRate: true)")
        #expect(enable != nil && prepare != nil && enable! < prepare!)
    }

    @Test func playersAreBuiltOnceAtFirstPlayNotOnShow() {
        let c = shown()
        #expect(tracks.isEmpty)
        c.play()
        #expect(tracks.count == 2)
        c.pause()
        let mic = tracks[.mic]
        c.play()
        #expect(tracks[.mic] === mic)
    }

    @Test func aTrackThatCannotBeOpenedIsDroppedAndNothingPlaysWhenNoneOpen() {
        failing = [.system]
        let c = shown()
        c.play()
        #expect(c.isPlaying)
        #expect(!c.timeline.has(.system))
        #expect(c.timeline.has(.mic))

        failing = [.mic, .system]
        let d = shown()
        d.play()
        #expect(!d.isPlaying)
        #expect(d.loadFailed)
    }

    @Test func aTrackWhosePreparationFailsCountsAsUnopened() {
        let c = controller()
        c.show(dir: a, tracks: [info(.mic)], lines: [])
        prepareFails = true
        c.play()
        #expect(!c.isPlaying)
        #expect(c.loadFailed)
    }

    @Test func aLaterSuccessfulPlayClearsLoadFailed() {
        failing = [.mic, .system]
        let c = shown()
        c.play()
        #expect(c.loadFailed)
        failing = []
        c.play()
        #expect(c.isPlaying)
        #expect(!c.loadFailed)
    }

    // MARK: - Stalled playback

    @Test func whenEverySoundingTrackStopsOnItsOwnThePlayerPausesAtTheLastKnownPosition() {
        let c = shown()
        c.play()
        clock.now += 0.5 + PlaybackController.startLead
        ticker.fire()
        let last = c.position
        #expect(last > 0)
        tracks[.mic]?.simulateStall()
        tracks[.system]?.simulateStall()
        clock.now += 3
        ticker.fire()
        #expect(!c.isPlaying)
        #expect(c.stalled)
        #expect(c.position == last, "no clock recompute: the position is the last one a tick saw")
        #expect(!ticker.isRunning)
        c.play()
        #expect(c.isPlaying)
        #expect(!c.stalled, "Play clears the notice")
    }

    @Test func oneTrackStillSoundingIsNotAStall() {
        let c = shown()
        c.play()
        clock.now += 2 + PlaybackController.startLead  // past the system track's 1.2 s offset: both sounding
        tracks[.mic]?.simulateStall()
        ticker.fire()
        #expect(c.isPlaying)
        #expect(!c.stalled)
    }

    @Test func aDecodeErrorFromATrackIsTheSameStall() {
        let c = shown()
        c.play()
        clock.now += 1 + PlaybackController.startLead
        ticker.fire()
        tracks[.mic]?.simulateDecodeError()
        #expect(!c.isPlaying)
        #expect(c.stalled)
        #expect(!ticker.isRunning)
    }

    @Test func reachingTheEndIsAFinishNotAStall() {
        let c = shown()
        c.play()
        clock.now += 25
        tracks[.mic]?.simulateStall()
        tracks[.system]?.simulateStall()
        ticker.fire()
        #expect(!c.isPlaying)
        #expect(!c.stalled)
        #expect(c.position == c.duration)
    }

    // MARK: - Duration fallback

    @Test func aZeroLengthFallsBackToThePlayersDurationAndRecomputesTheTimeline() {
        let c = shown([info(.mic, length: 0), info(.system, offsetMs: 1000, length: 0)], playerDuration: 9)
        #expect(c.timeline.isPlayable)
        #expect(c.timeline.tracks.allSatisfy { $0.length == 0 })
        c.play()
        #expect(abs(c.timeline.duration - 10) < 1e-9)
        #expect(abs(c.duration - 10) < 1e-9)
    }

    // MARK: - Position, seek, end

    @Test func thePositionFollowsTheDeviceClockAtTheRate() {
        let c = shown()
        c.play()
        clock.now += PlaybackController.startLead + 3
        ticker.fire()
        #expect(abs(c.position - 3.0) < 1e-9)
        c.rate = 2
        clock.now += 2
        ticker.fire()
        #expect(abs(c.position - 7.0) < 1e-9)   // 3 s + 2 s at 2x
    }

    @Test func seekWhilePlayingKeepsPlayingAndReschedulesEveryTrack() {
        let c = shown()
        c.play()
        clock.now += 5
        ticker.fire()
        log.events.removeAll()
        c.seek(to: 12)
        #expect(c.isPlaying)
        #expect(c.position == 12)
        #expect(tracks[.mic]?.setPositions.last == 12)
        #expect(abs((tracks[.system]?.setPositions.last ?? 0) - 10.8) < 1e-9)
        #expect(log.events.contains { $0.hasPrefix("mic.play(at:") })
        #expect(ticker.isRunning)
    }

    @Test func seekWhilePausedStaysPaused() {
        let c = shown()
        c.seek(to: 4)
        #expect(!c.isPlaying)
        #expect(c.position == 4)
        #expect(!ticker.isRunning)
    }

    @Test func seekIsClampedToTheSession() {
        let c = shown()
        c.seek(to: -5)
        #expect(c.position == 0)
        c.seek(to: 500)
        #expect(abs(c.position - 21.2) < 1e-9)
    }

    @Test func aLineClickSeeksHalfASecondBeforeItClampedAtZero() {
        let c = shown()
        c.seekToLine(startMs: 300)
        #expect(c.position == 0)
        c.seekToLine(startMs: 10_000)
        #expect(c.position == 9.5)
    }

    @Test func pausingFreezesThePositionAndStopsTheTicker() {
        let c = shown()
        c.play()
        clock.now += PlaybackController.startLead + 4
        ticker.fire()
        c.pause()
        #expect(!c.isPlaying)
        #expect(abs(c.position - 4) < 1e-9)
        #expect(!ticker.isRunning)
        #expect(log.events.contains("mic.pause"))
    }

    @Test func reachingTheEndStopsEverythingAndPlayAgainStartsOver() {
        let c = shown()
        c.play()
        clock.now += 60
        ticker.fire()
        #expect(!c.isPlaying)
        #expect(abs(c.position - 21.2) < 1e-9)
        #expect(!ticker.isRunning)
        #expect(log.events.contains("mic.stop"))
        c.play()
        #expect(c.isPlaying)
        #expect(c.position == 0)
        #expect(tracks[.mic]?.setPositions.last == 0)
    }

    @Test func theTickerRunsOnlyWhilePlaying() {
        let c = shown()
        #expect(!ticker.isRunning)
        c.play()
        #expect(ticker.isRunning)
        c.pause()
        #expect(!ticker.isRunning)
        c.play()
        #expect(ticker.isRunning)
        c.unload()
        #expect(!ticker.isRunning)
        #expect(ticker.startCount == 2)
    }

    // MARK: - Rate, volume, mute

    @Test func rateIsClampedToHalfThroughDouble() {
        let c = shown()
        c.rate = 0.3
        #expect(c.rate == 0.5)
        c.rate = 3
        #expect(c.rate == 2)
        c.rate = 1.5
        #expect(c.rate == 1.5)
    }

    @Test func aRateChangeReachesThePlayingTracks() {
        let c = shown()
        c.play()
        c.rate = 1.5
        #expect(tracks[.mic]?.rate == 1.5)
        #expect(tracks[.system]?.rate == 1.5)
    }

    @Test func aRateChangeWhilePlayingKeepsTheSessionPositionContinuous() {
        let c = shown()
        c.play()
        clock.now += PlaybackController.startLead + 6
        c.rate = 2
        #expect(abs(c.position - 6.0) < 1e-9)
        clock.now += 1
        ticker.fire()
        #expect(abs(c.position - 8.0) < 1e-9)
    }

    @Test func muteAndVolumeAreAppliedPerTrackAndUnmuteRestoresTheVolume() {
        let c = shown()
        c.play()
        c.setVolume(0.4, for: .system)
        #expect(tracks[.system]?.volume == 0.4)
        c.setMuted(true, for: .system)
        #expect(tracks[.system]?.volume == 0)
        #expect(tracks[.mic]?.volume == 1)
        c.setMuted(false, for: .system)
        #expect(tracks[.system]?.volume == 0.4)
        #expect(c.isMuted(.system) == false)
        #expect(c.volume(for: .system) == 0.4)
    }

    @Test func volumeSetBeforeTheFirstPlayIsAppliedWhenPlayersAreBuilt() {
        let c = shown()
        c.setMuted(true, for: .mic)
        c.setVolume(2, for: .system)   // clamped to 1
        c.play()
        #expect(tracks[.mic]?.volume == 0)
        #expect(tracks[.system]?.volume == 1)
    }

    // MARK: - Drift

    @Test func aTrackOffTheTimelineByMoreThanFiftyMillisecondsIsResynced() {
        let c = shown()
        c.play()
        clock.now += 3
        tracks[.mic]?.drift = 0.080
        ticker.fire()
        let expected = c.position
        #expect(tracks[.mic]?.setPositions.last == expected)
        #expect(tracks[.system]?.setPositions.count == 1, "the aligned track is left alone")
        _ = c
    }

    @Test func driftOfThirtyOrFortyNineMillisecondsIsLeftAlone() {
        let c = shown()
        c.play()
        clock.now += 3
        tracks[.mic]?.drift = 0.030
        ticker.fire()
        #expect(tracks[.mic]?.setPositions.count == 1)
        tracks[.mic]?.drift = 0.049
        ticker.fire()
        #expect(tracks[.mic]?.setPositions.count == 1)
    }

    @Test func driftOfFiftyOneMillisecondsIsResynced() {
        let c = shown()
        c.play()
        clock.now += 3
        tracks[.mic]?.drift = 0.051
        ticker.fire()
        #expect(tracks[.mic]?.setPositions.count == 2)
    }

    @Test func resyncsAreAtMostOncePerTwoSeconds() {
        let c = shown()
        c.play()
        clock.now += 3
        tracks[.mic]?.drift = 0.2
        ticker.fire()
        #expect(tracks[.mic]?.setPositions.count == 2)
        clock.now += 1
        tracks[.mic]?.drift = 0.2
        ticker.fire()
        #expect(tracks[.mic]?.setPositions.count == 2, "within 2 s of the last resync")
        clock.now += 1.5
        tracks[.mic]?.drift = 0.2
        ticker.fire()
        #expect(tracks[.mic]?.setPositions.count == 3)
    }

    @Test func noResyncDuringTheFirstTwoSecondsAfterStarting() {
        let c = shown()
        c.play()
        clock.now += 1
        tracks[.mic]?.drift = 0.3
        ticker.fire()
        #expect(tracks[.mic]?.setPositions.count == 1)
    }

    @Test func aTrackStillWaitingForItsStartIsNotCheckedForDrift() {
        let c = shown()
        c.rate = 0.5
        c.play()
        clock.now += PlaybackController.startLead + 2.01   // t = 1.005 s, system starts at 1.2 s
        tracks[.system]?.drift = 0.5
        ticker.fire()
        #expect(c.timeline.placement(of: .system, at: c.position) != nil)
        #expect(tracks[.system]?.setPositions.count == 1, "only the initial rewind")
    }

    // MARK: - show / reset

    @Test func anotherSessionUnloadsAndResetsRateMutesAndVolumes() {
        let c = shown()
        c.rate = 1.5
        c.setMuted(true, for: .mic)
        c.setVolume(0.3, for: .system)
        c.seek(to: 7)
        c.play()
        c.show(dir: b, tracks: [info(.mic)], lines: [])
        #expect(!c.isPlaying)
        #expect(!ticker.isRunning)
        #expect(c.rate == 1)
        #expect(!c.isMuted(.mic))
        #expect(c.volume(for: .system) == 1)
        #expect(c.position == 0)
        #expect(c.dir == b)
        #expect(log.events.contains("mic.stop"))
    }

    @Test func showingTheSameFolderAgainKeepsPlaying() {
        let c = shown()
        c.play()
        clock.now += 4
        ticker.fire()
        let position = c.position
        c.show(dir: a, tracks: both, lines: [])
        #expect(c.isPlaying)
        #expect(c.position == position)
        #expect(c.rate == 1)
    }

    @Test func showingTheSameFolderWithRereadLengthsDoesNotRestartWhenNothingChanged() {
        let c = shown([info(.mic, length: 0)], playerDuration: 9)
        c.play()
        let mic = tracks[.mic]
        c.show(dir: a, tracks: [info(.mic, length: 0)], lines: [])
        #expect(c.isPlaying)
        #expect(tracks[.mic] === mic)
        #expect(abs(c.duration - 9) < 1e-9, "the fallback length survives")
    }

    @Test func showingTheSameFolderWithDifferentTracksStopsPlayback() {
        let c = shown()
        c.play()
        c.show(dir: a, tracks: [info(.mic)], lines: [])
        #expect(!c.isPlaying)
        #expect(!c.timeline.has(.system))
    }

    @Test func unloadClearsTheSession() {
        let c = shown()
        c.play()
        c.unload()
        #expect(c.dir == nil)
        #expect(!c.isPlaying)
        #expect(c.gate == .noAudio)
        #expect(c.position == 0)
    }

    // MARK: - Gate

    @Test func theGateIsSeededFromTheRecordingStateAtInitAndOnShow() {
        recording = (b, false)
        let c = controller()
        c.show(dir: a, tracks: both, lines: [])
        #expect(c.gate == .pausedWhileRecording)
        #expect(!c.canPlay)
        recording = (nil, false)
        c.show(dir: a, tracks: both, lines: [])
        #expect(c.gate == .allowed, "re-read on every show")
        recording = (a, true)
        c.show(dir: a, tracks: both, lines: [])
        #expect(c.gate == .thisSessionRecording)
    }

    @Test func aFreshControllerReadsARecordingAlreadyRunning() {
        recording = (b, false)
        let c = controller()
        #expect(c.recordingDir == b)
        c.show(dir: a, tracks: both, lines: [])
        c.play()
        #expect(!c.isPlaying, "Play is disabled")
    }

    @Test func aRecordingStartingPausesPlaybackEvenWhenTheTapExcludesSelf() {
        let c = shown()
        c.play()
        c.recordingChanged(dir: b, excludesSelf: false)
        #expect(!c.isPlaying)
        #expect(c.gate == .pausedWhileRecording)
        #expect(!ticker.isRunning)
        c.play()
        #expect(!c.isPlaying)

        let d = shown()
        d.play()
        d.recordingChanged(dir: b, excludesSelf: true)
        #expect(!d.isPlaying)
        #expect(d.gate == .pausedWhileRecording)
    }

    @Test func whenTheRecordingEndsPlayIsEnabledAgainButNothingResumesByItself() {
        let c = shown()
        c.play()
        c.recordingChanged(dir: b, excludesSelf: false)
        c.recordingChanged(dir: nil, excludesSelf: false)
        #expect(c.gate == .allowed)
        #expect(!c.isPlaying)
        c.play()
        #expect(c.isPlaying)
    }

    @Test func theRecordedSessionItselfIsNeverPlayable() {
        let c = shown()
        c.recordingChanged(dir: a, excludesSelf: true)
        #expect(c.gate == .thisSessionRecording)
        c.play()
        #expect(!c.isPlaying)
    }

    @Test func aSessionWithoutTracksIsNoAudio() {
        let c = controller()
        c.show(dir: a, tracks: [], lines: [])
        #expect(c.gate == .noAudio)
        c.play()
        #expect(!c.isPlaying)
    }

    // MARK: - Current line

    private func lines(_ starts: [Int]) -> [TranscriptViewLine] {
        starts.enumerated().map { TranscriptViewLine(id: $0.offset, startMs: $0.element, speaker: "me", text: "x") }
    }

    @Test func theCurrentLineFollowsTheTimelineAndSeeks() {
        let c = shown(lines: lines([0, 4_000, 9_000]))
        #expect(c.currentLine == 0)
        c.seek(to: 5)
        #expect(c.currentLine == 1)
        c.play()
        clock.now += PlaybackController.startLead + 5
        ticker.fire()
        #expect(abs(c.position - 10) < 1e-9)
        #expect(c.currentLine == 2)
    }

    @Test func noLinesMeansNoCurrentLine() {
        let c = shown()
        #expect(c.currentLine == nil)
    }

    // MARK: - Follow epoch

    @Test func followEpochAdvancesOnPlayAndSeekButNotOnTicksOrPause() {
        let c = shown()
        let start = c.followEpoch
        c.play()
        #expect(c.followEpoch == start + 1)
        clock.now += 1
        ticker.fire()
        c.pause()
        #expect(c.followEpoch == start + 1)
        c.seek(to: 3)
        #expect(c.followEpoch == start + 2)
        c.seekToLine(startMs: 9_000)
        #expect(c.followEpoch == start + 3)
    }

    @Test func aRefusedPlayDoesNotAdvanceTheEpoch() {
        let c = controller()
        c.show(dir: a, tracks: [], lines: [])
        let start = c.followEpoch
        c.play()
        #expect(c.followEpoch == start)
    }

    @Test func hasMovedIsSetByPlayOrSeekAndClearedByAnotherSession() {
        let c = shown()
        #expect(!c.hasMoved)
        c.seek(to: 3)
        #expect(c.hasMoved)
        c.show(dir: b, tracks: both, lines: [])
        #expect(!c.hasMoved)
        c.play()
        #expect(c.hasMoved)
    }
}
