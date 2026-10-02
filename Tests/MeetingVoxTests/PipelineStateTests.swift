import Foundation
import Testing
@testable import MeetingVox

@Suite struct PipelineStateTests {
    private func reduce(_ events: [StageEvent], from start: PipelineState = PipelineState()) -> (state: PipelineState, finished: [PipelineState.Finished]) {
        var state = start
        var finished: [PipelineState.Finished] = []
        for event in events {
            let result = PipelineState.reduce(state, event)
            state = result.state
            finished += result.finished
        }
        return (state, finished)
    }

    // MARK: - Reducer

    @Test func runningMarksTheFolderActiveWithTheQueueDepth() {
        let state = reduce([.running(.minutes, folder: "A", queued: 2)]).state

        #expect(state.live(for: "A") == [.minutes: .running])
        #expect(state.queued(.minutes) == 2)
        #expect(state.live(for: "B").isEmpty)
    }

    @Test func stagesAreIndependent() {
        let state = reduce([
            .running(.transcription, folder: "A", queued: 0),
            .running(.summary, folder: "B", queued: 1),
        ]).state

        #expect(state.live(for: "A") == [.transcription: .running])
        #expect(state.live(for: "B") == [.summary: .running])
    }

    @Test func aNewRunningEventReplacesThePreviousFolderOfThatStage() {
        let result = reduce([
            .running(.minutes, folder: "A", queued: 1),
            .running(.minutes, folder: "B", queued: 0),
        ])

        #expect(result.state.live(for: "A").isEmpty)
        #expect(result.state.live(for: "B") == [.minutes: .running])
        #expect(result.finished == [.init(stage: .minutes, folder: "A")])
    }

    @Test func waitingRetryIsAnOverlayButNotRunning() {
        let state = reduce([.waitingRetry(.summary, folder: "A")]).state

        #expect(state.live(for: "A") == [.summary: .waitingRetry])
    }

    @Test func idleAndFailedClearTheOverlayOfThatStageOnly() {
        let base = reduce([
            .running(.minutes, folder: "A", queued: 0),
            .running(.summary, folder: "A", queued: 0),
        ]).state

        let afterIdle = reduce([.idle(.minutes)], from: base).state
        let afterFailed = reduce([.failed(.summary, folder: "A")], from: base).state

        #expect(afterIdle.live(for: "A") == [.summary: .running])
        #expect(afterFailed.live(for: "A") == [.minutes: .running])
    }

    @Test func failedNeverMarksAnythingFailed() {
        // PS-1: the store overlays only "active"; failure comes from markers.
        let state = reduce([
            .running(.minutes, folder: "A", queued: 0),
            .failed(.minutes, folder: "A"),
        ]).state

        #expect(state == PipelineState())
    }

    @Test func overlayClearedScenarioLeavesNoOverlayForTheFolder() {
        let result = reduce([
            .running(.transcription, folder: "D", queued: 0),
            .idle(.transcription),
        ])

        #expect(result.state == PipelineState())
        #expect(result.state.live(for: "D").isEmpty)
    }

    // MARK: - finished diff

    @Test func finishedIsReportedWhenActiveLeavesAFolder() {
        let result = reduce([
            .running(.transcription, folder: "A", queued: 0),
            .idle(.transcription),
        ])

        #expect(result.finished == [.init(stage: .transcription, folder: "A")])
    }

    @Test func finishedIsReportedOnFailureAndOnWaitingRetry() {
        let failed = reduce([.running(.minutes, folder: "A", queued: 0), .failed(.minutes, folder: "A")])
        let waiting = reduce([.running(.minutes, folder: "A", queued: 0), .waitingRetry(.minutes, folder: "A")])

        #expect(failed.finished == [.init(stage: .minutes, folder: "A")])
        #expect(waiting.finished == [.init(stage: .minutes, folder: "A")])
    }

    @Test func noFinishedWhenNothingWasActiveOrTheSameFolderKeepsRunning() {
        let idleFromNothing = reduce([.idle(.minutes)])
        let sameFolderTwice = reduce([
            .running(.minutes, folder: "A", queued: 1),
            .running(.minutes, folder: "A", queued: 0),
        ])

        #expect(idleFromNothing.finished.isEmpty)
        #expect(sameFolderTwice.finished.isEmpty)
        #expect(sameFolderTwice.state.queued(.minutes) == 0)
    }

    // MARK: - recording

    @Test func recordingEventSetsAndClearsTheCurrentRecording() {
        let dir = URL(fileURLWithPath: "/fake/2026.09.29-1100")

        let started = reduce([.recording(dir, elapsed: 12)])
        let ticked = reduce([.recording(dir, elapsed: 13)], from: started.state)
        let stopped = reduce([.recording(nil, elapsed: 0)], from: ticked.state)

        #expect(started.state.recording == PipelineState.Recording(dir: dir, elapsed: 12))
        #expect(ticked.state.recording?.elapsed == 13)
        #expect(stopped.state.recording == nil)
        #expect(started.finished.isEmpty && stopped.finished.isEmpty)
    }

    @Test func recordingDoesNotTouchTheStageOverlays() {
        let dir = URL(fileURLWithPath: "/fake/r")
        let state = reduce([
            .running(.minutes, folder: "A", queued: 0),
            .recording(dir, elapsed: 1),
        ]).state

        #expect(state.live(for: "A") == [.minutes: .running])
    }

    // MARK: - Status mapping

    @Test func transcriptionStatusesMapToEvents() {
        #expect(StageEvent(TranscriptionCoordinator.Status.idle) == .idle(.transcription))
        #expect(StageEvent(TranscriptionCoordinator.Status.transcribing(session: "A", queued: 3)) == .running(.transcription, folder: "A", queued: 3))
        #expect(StageEvent(TranscriptionCoordinator.Status.failed(session: "A")) == .failed(.transcription, folder: "A"))
    }

    @Test func minutesStatusesMapToEvents() {
        #expect(StageEvent(MinutesCoordinator.Status.idle) == .idle(.minutes))
        #expect(StageEvent(MinutesCoordinator.Status.generating(session: "A", queued: 1)) == .running(.minutes, folder: "A", queued: 1))
        #expect(StageEvent(MinutesCoordinator.Status.waitingRetry(session: "A")) == .waitingRetry(.minutes, folder: "A"))
        #expect(StageEvent(MinutesCoordinator.Status.failed(session: "A")) == .failed(.minutes, folder: "A"))
    }

    @Test func summaryStatusesMapToEvents() {
        #expect(StageEvent(SummaryCoordinator.Status.idle) == .idle(.summary))
        #expect(StageEvent(SummaryCoordinator.Status.generating(session: "A", queued: 0)) == .running(.summary, folder: "A", queued: 0))
        #expect(StageEvent(SummaryCoordinator.Status.waitingRetry(session: "A")) == .waitingRetry(.summary, folder: "A"))
        #expect(StageEvent(SummaryCoordinator.Status.failed(session: "A")) == .failed(.summary, folder: "A"))
    }

    @Test func extractingTasksNeverShowsAsASummaryRun() {
        // A tasks backfill is invisible to the Resumen pill and stepper.
        #expect(StageEvent(SummaryCoordinator.Status.extractingTasks(session: "A", queued: 2)) == .idle(.summary))
    }

    @Test func hindsightStatusesMapToEvents() {
        #expect(StageEvent(HindsightCoordinator.Status.idle) == .idle(.memory))
        #expect(StageEvent(HindsightCoordinator.Status.sending(session: "A")) == .running(.memory, folder: "A", queued: 0))
    }

    @Test func mappedEventsDriveTheReducerEndToEnd() {
        let result = reduce([
            StageEvent(MinutesCoordinator.Status.generating(session: "A", queued: 0)),
            StageEvent(MinutesCoordinator.Status.idle),
        ])

        #expect(result.finished == [.init(stage: .minutes, folder: "A")])
        #expect(result.state == PipelineState())
    }
}
