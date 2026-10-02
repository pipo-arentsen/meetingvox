import Foundation
import Testing
@testable import MeetingVox

@Suite struct PipelineStepperTests {
    private typealias S = PipelineStep.State

    private func derive(
        _ entry: MeetingEntry, memory: HindsightStatus? = nil, live: LiveStages = [:],
        recording: Bool = false, summaryApplies: Bool = true
    ) -> [PipelineStep] {
        PipelineStepper.derive(entry: entry, memory: memory, live: live, recording: recording, summaryApplies: summaryApplies)
    }

    private func states(_ steps: [PipelineStep]) -> [S] { steps.map(\.state) }

    private let sent = HindsightStatus.sent(Date(timeIntervalSince1970: 1_790_000_000), bank: nil)

    @Test func theFiveStepsAreInPipelineOrder() {
        let steps = derive(makeEntry())

        #expect(steps.map(\.kind) == [.grabada, .transcrita, .minuta, .resumen, .memoria])
        #expect(steps.map(\.title) == ["Grabada", "Transcrita", "Minuta", "Resumen", "Memoria"])
    }

    @Test func aCompleteSessionIsDoneEverywhere() {
        let steps = derive(makeEntry(hasMinutes: true, summaryState: .done), memory: sent)

        #expect(states(steps) == [.done, .done, .done, .done, .done])
    }

    // MARK: - Marker truth over live (PS-1)

    @Test func specScenarioMinutesActiveInTheStoreButMinutaMdExistsIsDone() {
        let steps = derive(makeEntry(hasMinutes: true), live: [.minutes: .running])

        #expect(steps[2].state == .done)
    }

    @Test func liveOverlaysOnlyActiveWhenThereIsNoMarker() {
        let entry = makeEntry(hasTranscript: false)
        let steps = derive(entry, live: [.transcription: .running])

        #expect(steps[1].state == .active)
        #expect(steps[0].state == .done)
    }

    @Test func overlayNeverProducesDoneOrFailed() {
        // Nothing on disk but a transcript; every stage claims to be running.
        let live: LiveStages = [.transcription: .running, .minutes: .running, .summary: .running, .memory: .running]
        let steps = derive(makeEntry(), memory: .notSent, live: live)

        #expect(states(steps) == [.done, .done, .active, .active, .active])
        #expect(!steps.dropFirst(2).contains { $0.state == .done || $0.state == .failed })
    }

    @Test func waitingRetryAlsoShowsAsActive() {
        #expect(derive(makeEntry(), live: [.minutes: .waitingRetry])[2].state == .active)
    }

    // MARK: - Disk markers

    @Test func pendingMarkersAreActive() {
        let steps = derive(makeEntry(minutesPending: true, summaryState: .pending))

        #expect(steps[2].state == .active)
        #expect(steps[3].state == .active)
    }

    @Test func pendingMarkerBeatsDoneOutputLikeSettlementFacts() {
        // A regeneration in flight keeps minuta.md but also has minuta.pendiente.
        #expect(derive(makeEntry(hasMinutes: true, minutesPending: true))[2].state == .active)
    }

    @Test func failedComesOnlyFromTheThreeErrorMarkers() {
        #expect(derive(makeEntry(minutesFailed: true))[2].state == .failed)
        #expect(derive(makeEntry(hasMinutes: true, summaryState: .failed))[3].state == .failed)
        #expect(derive(makeEntry(hasMinutes: true, summaryState: .done), memory: .error)[4].state == .failed)
        // A missing transcript is not a failure (no marker exists for it).
        #expect(!derive(makeEntry(hasTranscript: false)).contains { $0.state == .failed })
    }

    @Test func specScenarioMinutaErrorMakesLaterStepsPending() {
        let steps = derive(makeEntry(minutesFailed: true), memory: .pending, live: [.summary: .running])

        #expect(states(steps) == [.done, .done, .failed, .pending, .pending])
    }

    @Test func afterAMinutesFailureLaterStepsKeepDoneFailedAndSkipped() {
        let entry = makeEntry(minutesFailed: true, summaryState: .done)
        let doneAfter = derive(entry, memory: sent)
        let skippedAfter = derive(makeEntry(minutesFailed: true), summaryApplies: false)

        #expect(states(doneAfter) == [.done, .done, .failed, .done, .done])
        #expect(skippedAfter[3].state == .skipped)
        #expect(skippedAfter[4].state == .skipped)
    }

    // MARK: - Skipped and not-yet

    @Test func summarySkippedWhenItDoesNotApplyAndPendingWhenOwed() {
        #expect(derive(makeEntry(hasMinutes: true), summaryApplies: false)[3].state == .skipped)
        #expect(derive(makeEntry(hasMinutes: true), summaryApplies: true)[3].state == .pending)
    }

    @Test func memorySkippedWhenTheIntegrationIsOffOrTheUserOmittedIt() {
        #expect(derive(makeEntry(hasMinutes: true), memory: nil)[4].state == .skipped)
        #expect(derive(makeEntry(hasMinutes: true), memory: .omitted)[4].state == .skipped)
    }

    @Test func aSendableUnsentSessionShowsMemoryAsPendingSoItCanOfferToSend() {
        // Not sent yet, and it may be: a dashed ring with "Enviar", not a gray dash.
        #expect(derive(makeEntry(hasMinutes: true), memory: .notSent)[4].state == .pending)
        #expect(derive(makeEntry(hasMinutes: true), memory: .short)[4].state == .pending)
        // Live sending still turns it active; an omitted session ignores nothing but stays out.
        #expect(derive(makeEntry(hasMinutes: true), memory: .notSent, live: [.memory: .running])[4].state == .active)
        #expect(derive(makeEntry(hasMinutes: true), memory: .omitted, live: [.memory: .running])[4].state == .active)
    }

    @Test func memoryPendingActiveWhenSendingDoneWhenSent() {
        let entry = makeEntry(hasMinutes: true, summaryState: .done)
        #expect(derive(entry, memory: .pending)[4].state == .pending)
        #expect(derive(entry, memory: .pending, live: [.memory: .running])[4].state == .active)
        #expect(derive(entry, memory: sent, live: [.memory: .running])[4].state == .done)
    }

    @Test func minutesWithNoMarkerAfterATranscriptWereNeverRequested() {
        // Automatic minutes write minuta.pendiente right after the transcript,
        // so a transcript with no marker at all means minutes are off.
        #expect(derive(makeEntry())[2].state == .skipped)
    }

    @Test func withoutATranscriptEveryLaterStepWaits() {
        let steps = derive(makeEntry(hasTranscript: false))

        #expect(states(steps) == [.done, .pending, .pending, .pending, .pending])
    }

    // MARK: - Recording

    @Test func whileRecordingOnlyGrabadaIsActive() {
        let steps = derive(makeEntry(hasTranscript: false), live: [.transcription: .running], recording: true)

        #expect(states(steps) == [.active, .pending, .pending, .pending, .pending])
    }
}
