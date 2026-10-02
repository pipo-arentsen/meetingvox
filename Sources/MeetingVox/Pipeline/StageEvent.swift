import Foundation

/// One change reported by a pipeline stage or by the recorder, in a shape
/// `PipelineState.reduce` understands. The coordinators' `Status` enums are
/// not uniform (`TranscriptionCoordinator.Status` isn't even `Equatable`), so
/// each gets an `init` here and the reducer only ever sees this type.
///
/// `folder` is the session folder's name (`dir.lastPathComponent`), which is
/// what every coordinator publishes.
enum StageEvent: Equatable, Sendable {
    /// The stage has nothing running or queued.
    case idle(Notice.Stage)
    case running(Notice.Stage, folder: String, queued: Int)
    /// Every queued job of the stage is waiting for its retry delay.
    case waitingRetry(Notice.Stage, folder: String)
    /// The stage's last job failed. The overlay just clears: failure is read
    /// from the markers on disk, never from here.
    case failed(Notice.Stage, folder: String)
    /// The current recording; a nil folder means no recording. `elapsed` is
    /// in seconds.
    case recording(URL?, elapsed: TimeInterval)
}

extension StageEvent {
    init(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle: self = .idle(.transcription)
        case .transcribing(let session, let queued): self = .running(.transcription, folder: session, queued: queued)
        case .failed(let session): self = .failed(.transcription, folder: session)
        }
    }

    init(_ status: MinutesCoordinator.Status) {
        switch status {
        case .idle: self = .idle(.minutes)
        case .generating(let session, let queued): self = .running(.minutes, folder: session, queued: queued)
        case .waitingRetry(let session): self = .waitingRetry(.minutes, folder: session)
        case .failed(let session): self = .failed(.minutes, folder: session)
        }
    }

    init(_ status: SummaryCoordinator.Status) {
        switch status {
        case .idle: self = .idle(.summary)
        case .generating(let session, let queued): self = .running(.summary, folder: session, queued: queued)
        case .waitingRetry(let session): self = .waitingRetry(.summary, folder: session)
        case .failed(let session): self = .failed(.summary, folder: session)
        // A tasks backfill is invisible to the Resumen pill and stepper: the
        // overlay just clears (only the menu line shows it).
        case .extractingTasks: self = .idle(.summary)
        }
    }

    init(_ status: HindsightCoordinator.Status) {
        switch status {
        case .idle: self = .idle(.memory)
        case .sending(let session): self = .running(.memory, folder: session, queued: 0)
        }
    }
}
