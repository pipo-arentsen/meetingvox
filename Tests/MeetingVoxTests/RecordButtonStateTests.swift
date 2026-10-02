import Foundation
import Testing
@testable import MeetingVox

@Suite("RecordButtonState")
struct RecordButtonStateTests {
    @Test func elapsedTextIsMinutesAndSecondsThenHours() {
        #expect(ElapsedText.format(0) == "0:00")
        #expect(ElapsedText.format(9) == "0:09")
        #expect(ElapsedText.format(75) == "1:15")
        #expect(ElapsedText.format(3600) == "1:00:00")
        #expect(ElapsedText.format(3725) == "1:02:05")
    }

    @Test func aNegativeOrFractionalIntervalIsClamped() {
        #expect(ElapsedText.format(-5) == "0:00")
        #expect(ElapsedText.format(59.9) == "0:59")
    }

    @Test func withoutARecordingTheButtonStarts() {
        let state = RecordButtonState.of(nil)
        #expect(state == .start)
        #expect(!state.isRecording)
        #expect(state.title == "Grabar")
    }

    @Test func whileRecordingTheButtonStopsAndShowsTheClock() {
        let recording = PipelineState.Recording(dir: URL(fileURLWithPath: "/tmp/r/x"), elapsed: 754)
        let state = RecordButtonState.of(recording)
        #expect(state == .stop(elapsed: "12:34"))
        #expect(state.isRecording)
        #expect(state.title == "Detener 12:34")
    }
}
