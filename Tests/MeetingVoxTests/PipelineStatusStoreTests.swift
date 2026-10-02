import Foundation
import Observation
import Testing

@testable import MeetingVox

/// The main-actor box around `PipelineState.reduce` (PS-2): the app's status
/// handlers feed it, the window reads it. The reducer itself is covered by
/// `PipelineStateTests`; this is the wiring: what the store exposes, what it
/// reports as finished, and that it never invents state.
@MainActor
@Suite("PipelineStatusStore")
struct PipelineStatusStoreTests {
    private let dirA = URL(fileURLWithPath: "/tmp/rec/2026.09.29-1000", isDirectory: true)

    @Test func aRunningEventShowsTheFolderAsLiveUntilItGoesIdle() {
        let store = PipelineStatusStore()
        #expect(store.live(for: "A").isEmpty)

        store.apply(.running(.minutes, folder: "A", queued: 1))
        #expect(store.live(for: "A") == [.minutes: .running])
        #expect(store.live(for: "B").isEmpty)
        #expect(store.queued(.minutes) == 1)

        store.apply(.idle(.minutes))
        #expect(store.live(for: "A").isEmpty)
        #expect(store.queued(.minutes) == 0)
    }

    @Test func waitingRetryIsLiveButNotRunning() {
        let store = PipelineStatusStore()
        store.apply(.waitingRetry(.summary, folder: "A"))
        #expect(store.live(for: "A") == [.summary: .waitingRetry])
    }

    @Test func aFailedEventOnlyClearsTheOverlay() {
        let store = PipelineStatusStore()
        store.apply(.running(.transcription, folder: "A", queued: 0))
        store.apply(.failed(.transcription, folder: "A"))
        // PS-1: failure is read from the markers on disk, never from here.
        #expect(store.live(for: "A").isEmpty)
    }

    @Test func leavingAFolderReportsItAsFinishedSoTheWindowCanReload() {
        let store = PipelineStatusStore()
        var reported: [PipelineState.Finished] = []
        store.onFinished = { reported += $0 }

        store.apply(.running(.minutes, folder: "A", queued: 0))
        #expect(reported.isEmpty, "starting is not finishing")

        store.apply(.running(.minutes, folder: "B", queued: 0))
        #expect(reported == [.init(stage: .minutes, folder: "A")])

        store.apply(.idle(.minutes))
        #expect(reported == [.init(stage: .minutes, folder: "A"), .init(stage: .minutes, folder: "B")])
    }

    @Test func aRepeatedIdenticalEventReportsNothing() {
        let store = PipelineStatusStore()
        var calls = 0
        store.onFinished = { _ in calls += 1 }

        store.apply(.running(.summary, folder: "A", queued: 0))
        store.apply(.running(.summary, folder: "A", queued: 0))
        store.apply(.idle(.summary))
        store.apply(.idle(.summary))
        #expect(calls == 1, "only the transition out of A counts")
    }

    @Test func theRecordingIsTrackedApartFromTheStages() {
        let store = PipelineStatusStore()
        #expect(store.recording == nil)

        store.apply(.recording(dirA, elapsed: 0))
        #expect(store.recording?.dir == dirA)
        #expect(store.recording?.elapsed == 0)

        store.apply(.recording(dirA, elapsed: 75))
        #expect(store.recording?.elapsed == 75)
        #expect(store.live(for: dirA.lastPathComponent).isEmpty, "a recording is not a pipeline stage")

        store.apply(.recording(nil, elapsed: 0))
        #expect(store.recording == nil)
    }

    @Test func aRecordingTickDoesNotDisturbTheStagesOverlay() {
        let store = PipelineStatusStore()
        store.apply(.running(.minutes, folder: "A", queued: 0))
        var finished = 0
        store.onFinished = { _ in finished += 1 }

        for second in 1...3 { store.apply(.recording(dirA, elapsed: TimeInterval(second))) }

        #expect(store.live(for: "A") == [.minutes: .running])
        #expect(finished == 0)
    }

    @Test func theRealCoordinatorStatusesMapThroughTheSameEntryPoint() {
        let store = PipelineStatusStore()
        store.apply(StageEvent(TranscriptionCoordinator.Status.transcribing(session: "A", queued: 0)))
        store.apply(StageEvent(HindsightCoordinator.Status.sending(session: "A")))
        #expect(store.live(for: "A") == [.transcription: .running, .memory: .running])
    }

    // MARK: - What the list observes

    private final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func hit() { lock.withLock { _count += 1 } }
    }

    /// Runs `read` once under tracking; `fired.count` says whether anything it
    /// read changed afterwards (it fires at most once per arming).
    private func track(_ fired: Fired, _ read: () -> Void) {
        withObservationTracking(read) { fired.hit() }
    }

    @Test func recordingDirChangesOnlyWithTheFolderNotWithTheTick() {
        let store = PipelineStatusStore()
        #expect(store.recordingDir == nil)

        let started = Fired()
        track(started) { _ = store.recordingDir }
        store.apply(.recording(dirA, elapsed: 0))
        #expect(started.count == 1, "starting changes the folder")
        #expect(store.recordingDir == dirA)

        let ticked = Fired()
        track(ticked) { _ = store.recordingDir }
        for second in 1...5 { store.apply(.recording(dirA, elapsed: TimeInterval(second))) }
        #expect(ticked.count == 0, "the 1 s tick must not invalidate what the rows read")
        #expect(store.recordingDir == dirA)

        let stopped = Fired()
        track(stopped) { _ = store.recordingDir }
        store.apply(.recording(nil, elapsed: 0))
        #expect(stopped.count == 1)
        #expect(store.recordingDir == nil)
    }

    @Test func theElapsedClockStillTicksForTheTitleStrip() {
        let store = PipelineStatusStore()
        store.apply(.recording(dirA, elapsed: 0))
        let ticked = Fired()
        track(ticked) { _ = store.recording }
        store.apply(.recording(dirA, elapsed: 1))
        #expect(ticked.count == 1)
        #expect(store.recording?.elapsed == 1)
    }

    @Test func aRecordingTickDoesNotInvalidateTheStageOverlayReaders() {
        let store = PipelineStatusStore()
        store.apply(.running(.minutes, folder: "A", queued: 0))
        let fired = Fired()
        track(fired) { _ = store.live(for: "A") }

        store.apply(.recording(dirA, elapsed: 0))
        store.apply(.recording(dirA, elapsed: 1))
        #expect(fired.count == 0)

        store.apply(.idle(.minutes))
        #expect(fired.count == 1, "the control: a real stage change does invalidate")
    }

    // MARK: - Stopping a recording

    @Test func stoppingTheRecordingReportsItsFolderOnce() {
        let store = PipelineStatusStore()
        var stopped: [URL] = []
        store.onRecordingStopped = { stopped.append($0) }

        store.apply(.recording(dirA, elapsed: 0))
        store.apply(.recording(dirA, elapsed: 1))
        #expect(stopped.isEmpty, "starting and ticking are not stopping")

        store.apply(.recording(nil, elapsed: 0))
        #expect(stopped == [dirA])

        store.apply(.recording(nil, elapsed: 0))
        #expect(stopped == [dirA], "already stopped: nothing to report")
    }

    // MARK: - Recording gate inputs (player)

    @Test func excludesSelfDefaultsToFalse() {
        #expect(PipelineStatusStore().recordingExcludesSelf == false)
    }

    @Test func onRecordingStartedFiresOnceWhenTheFolderAppearsNotOnEveryTick() {
        let store = PipelineStatusStore()
        var started: [URL] = []
        store.onRecordingStarted = { started.append($0) }

        store.apply(.recording(dirA, elapsed: 0))
        for second in 1...5 { store.apply(.recording(dirA, elapsed: TimeInterval(second))) }
        #expect(started == [dirA], "the 1 s tick re-applies the same folder and must not refire")

        store.apply(.recording(nil, elapsed: 0))
        #expect(started == [dirA], "stopping is not starting")
        store.apply(.recording(dirA, elapsed: 0))
        #expect(started == [dirA, dirA])
    }

    @Test func aNewFolderWhileRecordingCountsAsAStartToo() {
        let store = PipelineStatusStore()
        let dirB = URL(fileURLWithPath: "/tmp/rec/2026.09.29-1100", isDirectory: true)
        var started: [URL] = []
        store.onRecordingStarted = { started.append($0) }
        store.apply(.recording(dirA, elapsed: 0))
        store.apply(.recording(dirB, elapsed: 0))
        #expect(started == [dirA, dirB])
    }

    @Test func stoppingResetsExcludesSelfBeforeTheStopCallbackRuns() {
        let store = PipelineStatusStore()
        var seenInCallback: Bool?
        store.onRecordingStopped = { _ in seenInCallback = store.recordingExcludesSelf }

        store.recordingExcludesSelf = true
        store.apply(.recording(dirA, elapsed: 0))
        store.apply(.recording(dirA, elapsed: 3))
        #expect(store.recordingExcludesSelf == true, "a tick keeps it")

        store.apply(.recording(nil, elapsed: 0))
        #expect(seenInCallback == false)
        #expect(store.recordingExcludesSelf == false)
    }
}
