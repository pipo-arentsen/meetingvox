import Foundation
import Testing
@testable import MeetingVox

/// When playback may run while a recording is in progress.
@Suite("PlaybackGate")
struct PlaybackGateTests {
    private let a = URL(fileURLWithPath: "/rec/2026.09.30-1000")
    private let b = URL(fileURLWithPath: "/rec/2026.09.30-1100")

    @Test func noRecordingAllowsASessionWithTracks() {
        #expect(PlaybackGate.decide(session: a, hasTracks: true, recordingDir: nil, excludesSelf: false) == .allowed)
    }

    @Test func noTracksIsNoAudio() {
        #expect(PlaybackGate.decide(session: a, hasTracks: false, recordingDir: nil, excludesSelf: false) == .noAudio)
    }

    @Test func theRecordedFolderIsNeverPlayableEvenWithoutMetaYet() {
        #expect(PlaybackGate.decide(session: a, hasTracks: false, recordingDir: a, excludesSelf: true) == .thisSessionRecording)
        #expect(PlaybackGate.decide(session: a, hasTracks: true, recordingDir: a, excludesSelf: true) == .thisSessionRecording)
    }

    @Test func anotherSessionPausesWhileRecordingWhetherOrNotTheTapExcludesSelf() {
        #expect(PlaybackGate.decide(session: b, hasTracks: true, recordingDir: a, excludesSelf: false) == .pausedWhileRecording)
        #expect(PlaybackGate.decide(session: b, hasTracks: true, recordingDir: a, excludesSelf: true) == .pausedWhileRecording,
                "speaker playback would leak into mic.caf even when the tap excludes this process")
    }

    @Test func noAudioBeatsTheRecordingPause() {
        #expect(PlaybackGate.decide(session: b, hasTracks: false, recordingDir: a, excludesSelf: false) == .noAudio)
    }

    @Test func foldersCompareStandardizedSoATrailingSlashStillMatches() {
        let slashed = URL(fileURLWithPath: "/rec/2026.09.30-1000/")
        let dotted = URL(fileURLWithPath: "/rec/./2026.09.30-1000")
        #expect(PlaybackGate.decide(session: slashed, hasTracks: true, recordingDir: a, excludesSelf: true) == .thisSessionRecording)
        #expect(PlaybackGate.decide(session: dotted, hasTracks: true, recordingDir: a, excludesSelf: true) == .thisSessionRecording)
    }

    @Test func noSessionIsNoAudio() {
        #expect(PlaybackGate.decide(session: nil, hasTracks: false, recordingDir: a, excludesSelf: false) == .noAudio)
    }

    @Test func onlyAllowedCanPlay() {
        #expect(PlaybackGate.allowed.canPlay)
        for gate in [PlaybackGate.noAudio, .pausedWhileRecording, .thisSessionRecording] { #expect(!gate.canPlay) }
    }
}
