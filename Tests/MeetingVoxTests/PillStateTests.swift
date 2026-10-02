import Testing
@testable import MeetingVox

/// The pill's pure reducer.
@Suite struct PillStateTests {
    private func run(_ events: [PillState.Event], from start: PillState = PillState()) -> PillState {
        var state = start
        for event in events { state.reduce(event) }
        return state
    }

    private let recording: [PillState.Event] = [.recordingStarted(pillEnabled: true)]

    @Test func startsHidden() {
        let state = PillState()
        #expect(state.face == .hidden)
        #expect(!state.isVisible)
        #expect(!state.isPromptVisible)
    }

    @Test func detectedThenRecordingKeepsTheWindow() {
        var state = run([.promptDetected(label: "Teams")])
        #expect(state.face == .detected("Teams"))
        #expect(state.isVisible)
        #expect(state.isPromptVisible)
        state.reduce(.recordingStarted(pillEnabled: true))
        #expect(state.face == .recording)
        #expect(state.isVisible)
        #expect(!state.isPromptVisible)
    }

    @Test func endPromptThenContinueOrWithdrawnReturnsToRecording() {
        var state = run(recording + [.promptEnded(title: "La reunión de Teams terminó")])
        #expect(state.face == .ended("La reunión de Teams terminó"))
        #expect(state.isPromptVisible)
        state.reduce(.promptClosed)
        #expect(state.face == .recording)
        #expect(!state.isPromptVisible)
        state.reduce(.promptEnded(title: "x"))
        state.reduce(.promptClosed)
        #expect(state.face == .recording)
    }

    @Test func userHideHidesUntilTheRecordingStops() {
        var state = run(recording + [.hideTapped])
        #expect(state.face == .hidden)
        #expect(!state.isVisible)
        state.reduce(.recordingStopped)
        #expect(state.face == .hidden)
        state.reduce(.recordingStarted(pillEnabled: true))
        #expect(state.face == .recording)
        #expect(state.isVisible)
    }

    @Test func silentMicResurfacesAHiddenPillAndRecoveryReturnsToRecording() {
        var state = run(recording + [.hideTapped, .micSilent])
        #expect(state.face == .silentMic)
        #expect(state.isVisible)
        state.reduce(.micBack)
        #expect(state.face == .recording)
        #expect(state.isVisible)
    }

    @Test func micBackNeverRehides() {
        let state = run(recording + [.micSilent, .hideTapped, .micBack])
        #expect(state.face == .hidden)
    }

    @Test func silentMicDoesNotResurfaceWhenTheSettingIsOff() {
        var state = run([.recordingStarted(pillEnabled: false)])
        #expect(state.face == .hidden)
        state.reduce(.micSilent)
        #expect(state.face == .hidden)
        #expect(!state.isVisible)
        state.reduce(.micBack)
        #expect(state.face == .hidden)
    }

    @Test func settingOffKeepsPromptsButNotTheRecordingFaces() {
        var state = run([.settingChanged(false), .promptDetected(label: "Zoom")])
        #expect(state.face == .detected("Zoom"))
        #expect(state.isVisible)
        state.reduce(.recordingStarted(pillEnabled: false))
        #expect(state.face == .hidden)
        state.reduce(.promptEnded(title: "fin"))
        #expect(state.face == .ended("fin"))
        #expect(state.isVisible)
        state.reduce(.promptClosed)
        #expect(state.face == .hidden)
    }

    @Test func settingChangedMidRecordingShowsOrHides() {
        var state = run(recording)
        state.reduce(.settingChanged(false))
        #expect(state.face == .hidden)
        state.reduce(.settingChanged(true))
        #expect(state.face == .recording)
    }

    @Test func reenablingTheSettingClearsAUserHide() {
        var state = run(recording + [.hideTapped])
        #expect(state.face == .hidden)
        state.reduce(.settingChanged(true))
        #expect(state.face == .recording)
    }

    @Test func endedTakesPrecedenceOverSilentMic() {
        var state = run(recording + [.micSilent, .promptEnded(title: "fin")])
        #expect(state.face == .ended("fin"))
        // A recovery while the end prompt is up applies on return.
        state.reduce(.micBack)
        #expect(state.face == .ended("fin"))
        state.reduce(.promptClosed)
        #expect(state.face == .recording)
    }

    @Test func endedShowsOverAHiddenRecording() {
        var state = run(recording + [.hideTapped, .promptEnded(title: "fin")])
        #expect(state.face == .ended("fin"))
        #expect(state.isVisible)
        state.reduce(.promptClosed)
        #expect(state.face == .hidden)
    }

    @Test func recordingStoppedClearsEverythingButADetectedPrompt() {
        var state = run(recording + [.micSilent, .promptEnded(title: "fin"), .recordingStopped])
        #expect(state.face == .hidden)
        #expect(!state.isPromptVisible)
        state = run([.promptDetected(label: "Teams"), .recordingStopped])
        #expect(state.face == .detected("Teams"))
    }

    @Test func isPromptVisibleIsFalseForEveryRecordingFace() {
        #expect(!run(recording).isPromptVisible)
        #expect(!run(recording + [.hideTapped]).isPromptVisible)
        #expect(!run(recording + [.micSilent]).isPromptVisible)
        #expect(run(recording + [.promptEnded(title: "x")]).isPromptVisible)
    }

    @Test func aDetectedPromptDuringARecordingIsIgnored() {
        let state = run(recording + [.promptDetected(label: "Teams")])
        #expect(state.face == .recording)
        #expect(!state.isPromptVisible)
    }

    @Test func aSecondDetectedPromptKeepsTheFirst() {
        let state = run([.promptDetected(label: "Teams"), .promptDetected(label: "Zoom")])
        #expect(state.face == .detected("Teams"))
    }

    @Test func recordingStartedClearsADetectedPrompt() {
        let state = run([.promptDetected(label: "Teams"), .recordingStarted(pillEnabled: true)])
        #expect(!state.isPromptVisible)
    }

    @Test func eventsWithoutARecordingAreNoOps() {
        let state = run([.hideTapped, .micSilent, .micBack, .promptClosed, .recordingStopped])
        #expect(state == PillState())
    }
}
