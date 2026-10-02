import Testing

@testable import MeetingVox

/// One decision for every way out (⌘Q, menu Quit, SIGTERM, SIGINT, logout,
/// launchd bootout): a live recording is stopped (meta.json written) before
/// the app replies to terminate.
@Suite("TerminationPolicy")
struct TerminationPolicyTests {
    @Test func idleTerminatesImmediately() {
        #expect(TerminationPolicy.decide(isRecording: false, alreadyTerminating: false) == .now)
    }

    @Test func aLiveRecordingIsStoppedThenTerminationIsDeferredByTheDrain() {
        #expect(TerminationPolicy.decide(isRecording: true, alreadyTerminating: false)
            == .stopThenLater(drain: TerminationPolicy.drain))
    }

    @Test func aSecondRequestWhileOneIsInFlightDoesNotStopOrDeferAgain() {
        // Still recording on paper (the first request is mid-drain) or already
        // stopped by it: either way the in-flight reply is the one that counts.
        #expect(TerminationPolicy.decide(isRecording: true, alreadyTerminating: true) == .alreadyInProgress)
        #expect(TerminationPolicy.decide(isRecording: false, alreadyTerminating: true) == .alreadyInProgress)
    }

    @Test func theDrainIsShortEnoughForLaunchdsExitTimeout() {
        // The agent plist relies on launchd's 20 s default before SIGKILL.
        #expect(TerminationPolicy.drain > 0)
        #expect(TerminationPolicy.drain < 20)
    }
}
