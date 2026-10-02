import Testing

@testable import MeetingVox

/// ⌘Q and the menu bar's Salir: with a recording in progress the user is asked
/// first; otherwise the app quits at once. Signals and logout never ask (they
/// call `NSApp.terminate`, which `TerminationPolicy` decides).
@Suite("QuitDecision")
struct QuitDecisionTests {
    @Test func idleTerminatesWithoutAsking() {
        #expect(QuitDecision.decide(isRecording: false) == .terminate)
    }

    @Test func aLiveRecordingAsksForConfirmation() {
        #expect(QuitDecision.decide(isRecording: true) == .confirm)
    }

    @Test func onlyTheStopAndQuitAnswerTerminates() {
        #expect(QuitDecision.Answer.stopAndQuit.terminates)
        #expect(!QuitDecision.Answer.cancel.terminates)
    }

    @Test func theAlertButtonsMapToAnswersFirstIsStopAndQuit() {
        // NSAlert numbers buttons in the order they were added: the first one
        // (the default, Return) is "Detener y salir", the second "Cancelar".
        #expect(QuitDecision.Answer(buttonIndex: 0) == .stopAndQuit)
        #expect(QuitDecision.Answer(buttonIndex: 1) == .cancel)
        // Anything else (a dismissed alert) keeps the recording going.
        #expect(QuitDecision.Answer(buttonIndex: 2) == .cancel)
        #expect(QuitDecision.Answer(buttonIndex: -1) == .cancel)
    }

    @Test func theConfirmationCopyNamesTheRecordingAndBothChoices() {
        #expect(Textos.Salir.pregunta == "Hay una grabación en curso. ¿Detener y salir?")
        #expect(Textos.Salir.detenerYSalir == "Detener y salir")
        #expect(Textos.Salir.cancelar == "Cancelar")
    }

    // MARK: - Who asked (Dock menu Quit, logout, signals)

    private func code(_ four: String) -> UInt32 {
        four.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private var aevt: UInt32 { code("aevt") }
    private var quit: UInt32 { code("quit") }

    @Test func aQuitEventWithoutAReasonIsAPersonQuitting() {
        // The Dock menu's Quit (and `tell application ... to quit`).
        #expect(QuitOrigin.classify(eventClass: aevt, eventID: quit, reason: nil) == .userAppleEvent)
    }

    @Test func everyReasonMeansTheSystemIsQuittingUs() {
        // logout, restart, shutdown, "quit all": never any UI.
        for reason in ["rlgo", "rrst", "rsdn", "rest", "shut", "quia", "????"] {
            #expect(
                QuitOrigin.classify(eventClass: aevt, eventID: quit, reason: code(reason)) == .system,
                "reason \(reason)"
            )
        }
    }

    @Test func noAppleEventOrAnotherOneIsProgrammatic() {
        // SIGTERM / launchctl bootout / requestQuit's own terminate arrive with no event.
        #expect(QuitOrigin.classify(eventClass: nil, eventID: nil, reason: nil) == .programmatic)
        #expect(QuitOrigin.classify(eventClass: aevt, eventID: code("oapp"), reason: nil) == .programmatic)
        #expect(QuitOrigin.classify(eventClass: code("misc"), eventID: quit, reason: nil) == .programmatic)
    }

    @Test func onlyAnUnconfirmedPersonQuitDuringARecordingAsksFirst() {
        #expect(QuitDecision.atTermination(isRecording: true, origin: .userAppleEvent, alreadyConfirmed: false) == .askFirst)
    }

    @Test func everyOtherCombinationTerminatesWithoutUI() {
        // Already confirmed through requestQuit: no second alert.
        #expect(QuitDecision.atTermination(isRecording: true, origin: .userAppleEvent, alreadyConfirmed: true) == .allow)
        // System reasons and signals must never show UI, recording or not.
        #expect(QuitDecision.atTermination(isRecording: true, origin: .system, alreadyConfirmed: false) == .allow)
        #expect(QuitDecision.atTermination(isRecording: true, origin: .programmatic, alreadyConfirmed: false) == .allow)
        // Nothing to lose.
        #expect(QuitDecision.atTermination(isRecording: false, origin: .userAppleEvent, alreadyConfirmed: false) == .allow)
    }

    // MARK: - Unsaved template draft

    @Test func questionsAreAskedRecordingFirstThenTheDraft() {
        #expect(QuitDecision.questions(isRecording: false, draft: nil).isEmpty)
        #expect(QuitDecision.questions(isRecording: true, draft: nil) == [.stopRecording])
        #expect(QuitDecision.questions(isRecording: false, draft: "Minuta general") == [.saveDraft("Minuta general")])
        #expect(QuitDecision.questions(isRecording: true, draft: "Daily") == [.stopRecording, .saveDraft("Daily")])
    }

    @Test func theDraftAnswerFollowsTheButtonOrderAndUnexpectedIsCancel() {
        #expect(QuitDecision.DraftAnswer(buttonIndex: 0) == .save)
        #expect(QuitDecision.DraftAnswer(buttonIndex: 1) == .discard)
        #expect(QuitDecision.DraftAnswer(buttonIndex: 2) == .cancel)
        #expect(QuitDecision.DraftAnswer(buttonIndex: 3) == .cancel)
        #expect(QuitDecision.DraftAnswer(buttonIndex: -1) == .cancel)
    }

    @Test func savingOnlyLetsTheAppQuitWhenTheSaveWorked() {
        #expect(QuitDecision.DraftAnswer.save.proceeds(saved: true))
        #expect(!QuitDecision.DraftAnswer.save.proceeds(saved: false)) // conflict, write error: stay and show it
        #expect(QuitDecision.DraftAnswer.discard.proceeds(saved: false))
        #expect(!QuitDecision.DraftAnswer.cancel.proceeds(saved: true))
    }

    @Test func aPersonQuittingFromTheDockWithADraftIsAskedFirstToo() {
        #expect(QuitDecision.atTermination(isRecording: false, hasDraft: true, origin: .userAppleEvent, alreadyConfirmed: false) == .askFirst)
        #expect(QuitDecision.atTermination(isRecording: true, hasDraft: true, origin: .userAppleEvent, alreadyConfirmed: false) == .askFirst)
    }

    @Test func aDraftNeverBlocksLogoutSignalsOrAnAlreadyConfirmedQuit() {
        #expect(QuitDecision.atTermination(isRecording: false, hasDraft: true, origin: .system, alreadyConfirmed: false) == .allow)
        #expect(QuitDecision.atTermination(isRecording: false, hasDraft: true, origin: .programmatic, alreadyConfirmed: false) == .allow)
        #expect(QuitDecision.atTermination(isRecording: false, hasDraft: true, origin: .userAppleEvent, alreadyConfirmed: true) == .allow)
        #expect(QuitDecision.atTermination(isRecording: false, hasDraft: false, origin: .userAppleEvent, alreadyConfirmed: false) == .allow)
    }
}
