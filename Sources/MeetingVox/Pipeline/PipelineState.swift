import Foundation

/// What a stage is doing for one session right now, as far as the running
/// app knows. It never says "done" or "failed": those come from the markers
/// on disk (PS-1).
enum LiveStage: Equatable, Sendable {
    case running
    case waitingRetry
}

typealias LiveStages = [Notice.Stage: LiveStage]

/// The in-memory overlay of the pipeline: which folder each stage is working
/// on, plus the current recording. Pure value with a pure `reduce` (PS-4), so
/// `PipelineStatusStore` (main actor, observable) is just a box around it.
struct PipelineState: Equatable, Sendable {
    struct Overlay: Equatable, Sendable {
        var active: String?
        var queued = 0
        var waitingRetry: String?
    }

    struct Recording: Equatable, Sendable {
        let dir: URL
        let elapsed: TimeInterval
    }

    /// `active` left `folder` of `stage`: the disk has probably changed, so
    /// the window reloads.
    struct Finished: Equatable, Sendable {
        let stage: Notice.Stage
        let folder: String
    }

    /// Only stages with something to show; an idle stage has no entry, so a
    /// fully cleared state equals `PipelineState()`.
    private(set) var overlays: [Notice.Stage: Overlay] = [:]
    private(set) var recording: Recording?

    init() {}

    /// Jobs waiting behind the running one, as the stage last reported.
    func queued(_ stage: Notice.Stage) -> Int { overlays[stage]?.queued ?? 0 }

    /// The live stages of one session folder.
    func live(for folder: String) -> LiveStages { Self.live(for: folder, in: overlays) }

    /// The same over bare overlays, for the store, which keeps only those.
    static func live(for folder: String, in overlays: [Notice.Stage: Overlay]) -> LiveStages {
        var result: LiveStages = [:]
        for (stage, overlay) in overlays {
            if overlay.active == folder {
                result[stage] = .running
            } else if overlay.waitingRetry == folder {
                result[stage] = .waitingRetry
            }
        }
        return result
    }

    /// - Returns: the next state and the (stage, folder) pairs whose `active`
    ///   left that folder in this step.
    static func reduce(_ state: PipelineState, _ event: StageEvent) -> (state: PipelineState, finished: [Finished]) {
        var next = state
        switch event {
        case .idle(let stage), .failed(let stage, _):
            next.overlays[stage] = nil
        case .running(let stage, let folder, let queued):
            next.overlays[stage] = Overlay(active: folder, queued: max(0, queued), waitingRetry: nil)
        case .waitingRetry(let stage, let folder):
            next.overlays[stage] = Overlay(active: nil, queued: 0, waitingRetry: folder)
        case .recording(let dir, let elapsed):
            next.recording = dir.map { Recording(dir: $0, elapsed: elapsed) }
        }

        var finished: [Finished] = []
        for (stage, overlay) in state.overlays {
            guard let folder = overlay.active, next.overlays[stage]?.active != folder else { continue }
            finished.append(Finished(stage: stage, folder: folder))
        }
        return (next, finished)
    }
}
