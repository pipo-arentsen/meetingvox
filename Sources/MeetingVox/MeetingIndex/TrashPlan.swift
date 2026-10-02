import Foundation

/// What "Mover a la papelera…" will do with a selection, decided before the
/// confirmation sheet: which sessions may go and which are skipped (and why).
/// Pure — the live overlay, the recording folder and the memory facts arrive
/// as values — so every rule is a test and the sheet only draws it.
///
/// A session is blocked while it is the folder being recorded, while a
/// pipeline stage is working on it (running or waiting to retry), or while
/// work is still owed (a `*.pendiente` marker, a Hindsight request, or a
/// transcription queued or running): moving the folder under a job — or one that
/// resumes at the next launch — would lose its output or recreate the folder.
struct TrashPlan: Equatable, Sendable {
    enum BlockReason: Equatable, Sendable {
        /// The folder being recorded right now.
        case recording
        /// A pipeline stage is running or waiting to retry for it.
        case working(Notice.Stage)
        /// Work is still owed: an on-disk request (`hasPendingWorkOnDisk`) or a
        /// transcription queued or running (asked of the coordinator).
        case pending
    }

    struct Blocked: Equatable, Sendable {
        let dir: URL
        let reason: BlockReason
    }

    /// In selection order.
    let trashable: [URL]
    let blocked: [Blocked]
    /// True when some trashable session reached Hindsight and the integration
    /// is on: the sheet then offers "Borrar también de la memoria".
    let offersMemoryDelete: Bool

    /// - Parameters:
    ///   - liveOverlay: the live stages of a session folder name
    ///     (`PipelineStatusStore.live(for:)`).
    ///   - isInMemory: the session has a v2 `hindsight.json`.
    ///   - memoryEnabled: `hindsight.enabled`.
    ///   - hasPendingWork: work is still owed for the session (on-disk
    ///     markers plus the transcription queue; async facts are gathered by
    ///     the caller first, so this stays pure).
    static func make(
        sessions: [URL], recordingDir: URL?, liveOverlay: (String) -> LiveStages,
        isInMemory: (URL) -> Bool, memoryEnabled: Bool, hasPendingWork: (URL) -> Bool
    ) -> TrashPlan {
        let recordingPath = recordingDir?.standardizedFileURL.path
        var trashable: [URL] = []
        var blocked: [Blocked] = []
        for dir in sessions {
            if let reason = blockReason(dir, recordingPath: recordingPath, liveOverlay: liveOverlay, hasPendingWork: hasPendingWork) {
                blocked.append(Blocked(dir: dir, reason: reason))
            } else {
                trashable.append(dir)
            }
        }
        return TrashPlan(
            trashable: trashable, blocked: blocked,
            offersMemoryDelete: memoryEnabled && trashable.contains(where: isInMemory)
        )
    }

    private static func blockReason(
        _ dir: URL, recordingPath: String?, liveOverlay: (String) -> LiveStages, hasPendingWork: (URL) -> Bool
    ) -> BlockReason? {
        if dir.standardizedFileURL.path == recordingPath { return .recording }
        let live = liveOverlay(dir.lastPathComponent)
        // Fixed order so the sentence is stable when several stages are live.
        for stage in [Notice.Stage.transcription, .minutes, .summary, .memory] where live[stage] != nil {
            return .working(stage)
        }
        return hasPendingWork(dir) ? .pending : nil
    }

    /// The on-disk requests that outlive the live overlay (the filesystem is
    /// the queue): `minuta.pendiente`, `resumen.pendiente`, `tareas.pendiente`
    /// and `hindsight.solicitado` are resumed at launch. A missing
    /// `transcript.json` is deliberately NOT a rule: a transcription that
    /// failed for good (or an empty test recording) leaves exactly that, and
    /// those are the sessions the user wants to delete. A transcription still
    /// queued or running is asked of `TranscriptionCoordinator.isQueuedOrRunning`.
    /// Trashing one of these would have a job resume against a missing folder.
    static func hasPendingWorkOnDisk(_ dir: URL) -> Bool {
        [
            SessionFiles.minutesPending, SessionFiles.summaryPending, SessionFiles.tasksPending,
            SessionFiles.hindsightRequested,
        ].contains { SessionFiles.exists($0, in: dir) }
    }
}
