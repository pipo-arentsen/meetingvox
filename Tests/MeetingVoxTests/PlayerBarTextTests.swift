import Foundation
import Testing
@testable import MeetingVox

/// The player bar's copy rules: speed labels, the clock, and what a
/// disabled bar says.
@MainActor
@Suite("PlayerBarText")
struct PlayerBarTextTests {
    @Test func speedLabelsUseASpanishDecimalComma() {
        #expect(PlayerBarText.speed(0.5) == "0,5×")
        #expect(PlayerBarText.speed(0.75) == "0,75×")
        #expect(PlayerBarText.speed(1) == "1×")
        #expect(PlayerBarText.speed(1.25) == "1,25×")
        #expect(PlayerBarText.speed(1.5) == "1,5×")
        #expect(PlayerBarText.speed(2) == "2×")
    }

    @Test func theSpeedChoicesStayInsideTheClampedRange() {
        #expect(PlayerBarText.speeds.first == PlaybackController.rateRange.lowerBound)
        #expect(PlayerBarText.speeds.last == PlaybackController.rateRange.upperBound)
        #expect(PlayerBarText.speeds.contains(1))
    }

    @Test func theClockMatchesTheTranscriptStamps() {
        #expect(PlayerBarText.clock(0) == "00:00")
        #expect(PlayerBarText.clock(38.6) == "00:38")
        #expect(PlayerBarText.clock(754) == "12:34")
        #expect(PlayerBarText.clock(3_725) == "1:02:05")
        #expect(PlayerBarText.clock(-4) == "00:00")
    }

    @Test func onlyAnAllowedGateSaysNothing() {
        #expect(PlayerBarText.message(for: .allowed) == nil)
        #expect(PlayerBarText.message(for: .pausedWhileRecording) == Textos.Reproductor.pausadoGrabando)
        #expect(PlayerBarText.message(for: .thisSessionRecording) == Textos.Reproductor.estaSesionGrabando)
        #expect(PlayerBarText.message(for: .noAudio) == Textos.Reproductor.sinAudio)
    }

    @Test func theBarIsHiddenOnlyWhenThereIsNoAudioAtAll() {
        #expect(PlayerBarText.showsBar(for: .allowed))
        #expect(PlayerBarText.showsBar(for: .pausedWhileRecording))
        #expect(PlayerBarText.showsBar(for: .thisSessionRecording))
        #expect(!PlayerBarText.showsBar(for: .noAudio))
    }

    @Test func theCopyIsDistinctAndNeverMentionsALog() {
        let all = [Textos.Reproductor.pausadoGrabando, Textos.Reproductor.estaSesionGrabando, Textos.Reproductor.sinAudio, Textos.Reproductor.noSeAbrio]
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { !$0.lowercased().contains("log") })
    }

    @Test func stalledAndLoadFailedHaveTheirOwnLines() {
        #expect(PlayerBarText.message(for: .allowed, loadFailed: false, stalled: true) == Textos.Reproductor.seDetuvo)
        #expect(PlayerBarText.message(for: .allowed, loadFailed: true, stalled: false) == Textos.Reproductor.noSeAbrio)
        #expect(PlayerBarText.message(for: .pausedWhileRecording, loadFailed: false, stalled: true) == Textos.Reproductor.pausadoGrabando)
        #expect(PlayerBarText.message(for: .allowed, loadFailed: false, stalled: false) == nil)
    }
}
