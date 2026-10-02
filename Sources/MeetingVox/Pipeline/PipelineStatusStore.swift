import Foundation
import Observation

/// The main window's view of what the running app is doing right now (PS-1,
/// PS-2): a main-actor, observable box around the pure `PipelineState.reduce`.
/// The coordinators' existing status handlers feed it (`AppController` calls
/// `apply` from inside them, it replaces none) and so does the recorder.
///
/// It only ever overlays "active" (running, queued, waiting to retry). It never
/// says a step is done or failed: that is the markers on disk.
///
/// What the views observe is split by how often it changes, because the
/// recording ticks once a second and must not redraw every row: the stage
/// overlays change with the pipeline, `recordingDir` only when the recorded
/// folder does (this is what the rows read), and `recording` (with the
/// elapsed seconds) is for the title strip's clock alone.
@MainActor
@Observable
final class PipelineStatusStore {
    /// Just the stage overlays: no copy of the recording lives here.
    private var overlays: [Notice.Stage: PipelineState.Overlay] = [:]
    private(set) var recording: PipelineState.Recording?
    /// The folder being recorded; unlike `recording` it does not change on a tick.
    private(set) var recordingDir: URL?

    /// A stage's `active` left a folder (the disk has probably changed).
    /// `MainWindowModel` reloads on it. Not observed.
    @ObservationIgnored var onFinished: (([PipelineState.Finished]) -> Void)?
    /// The recording ended (its folder is now a session with a `meta.json`).
    /// Not observed.
    @ObservationIgnored var onRecordingStopped: ((URL) -> Void)?
    /// A recording began (the folder appeared or changed); never on the 1 s
    /// tick that re-applies the same folder. Not observed.
    @ObservationIgnored var onRecordingStarted: ((URL) -> Void)?

    /// Whether the running recording's system tap excludes this process, so
    /// playback may continue without leaking into `system.caf`. The recorder's
    /// owner sets it before applying `.recording(dir, …)`; it is reset to
    /// false when the recording ends, before `onRecordingStopped` runs.
    var recordingExcludesSelf = false

    /// The full state, including the recording; the source of truth the
    /// observable views above are cut from.
    @ObservationIgnored private var core = PipelineState()

    init() {}

    /// The live stages of one session folder (`dir.lastPathComponent`).
    func live(for folder: String) -> LiveStages { PipelineState.live(for: folder, in: overlays) }

    /// Jobs waiting behind the running one, as the stage last reported.
    func queued(_ stage: Notice.Stage) -> Int { overlays[stage]?.queued ?? 0 }

    func apply(_ event: StageEvent) {
        let previousDir = core.recording?.dir
        let (next, finished) = PipelineState.reduce(core, event)
        core = next
        // Assign only what changed, so observers of the other parts stay quiet.
        if next.overlays != overlays { overlays = next.overlays }
        if next.recording != recording { recording = next.recording }
        if next.recording?.dir != recordingDir { recordingDir = next.recording?.dir }
        if !finished.isEmpty { onFinished?(finished) }
        if let dir = next.recording?.dir, dir != previousDir { onRecordingStarted?(dir) }
        if let previousDir, next.recording == nil {
            recordingExcludesSelf = false
            onRecordingStopped?(previousDir)
        }
    }
}
