import SwiftUI

/// The session detail's snapshot states: the header, chips, toolbar
/// and stepper for a complete session, a minutes error, no minutes, a memory
/// send in progress, a sent session and work still running, plus the bulk
/// panel and the stepper's five looks on their own. Full-window states use
/// `flatColumns` like the main window ones.
enum SnapshotDetailStates {
    static let windowSize = MainLayout.defaultSize

    @MainActor
    static var all: [SnapshotState] {
        [complete, minutesError, retryRefused, noMinutes, sendingMemory, sentMemory, inProgress, bulk, trashConfirmation, trashConfirmationBlocked, stepperLooks]
    }

    /// The fixture session of `kind` selected and its detail data read; the
    /// store may carry a live overlay.
    @MainActor
    private static func detail(
        _ context: SnapshotContext, _ kind: SnapshotFixtures.Kind, store: PipelineStatusStore = PipelineStatusStore(),
        live: (PipelineStatusStore, String) -> Void = { _, _ in },
        after: (MainWindowModel, MeetingEntry) -> Void = { _, _ in }
    ) -> AnyView {
        let model = context.env.makeMainWindowModel(store: store)
        SnapshotEnvironment.load(model)
        if let fixture = context.installed.dirs(of: kind).first,
           let entry = model.meetings.entries.first(where: { $0.dir.standardizedFileURL == fixture.standardizedFileURL }) {
            model.meetings.selection = [entry.dir]
            live(store, entry.dir.lastPathComponent)
            SnapshotEnvironment.loadDetail(model)
            after(model, entry)
        }
        return AnyView(MainView(model: model, onToggleRecording: {}, flatColumns: true))
    }

    @MainActor
    static let complete = SnapshotState(name: "detail-complete", width: windowSize.width, height: windowSize.height) {
        detail($0, .complete)
    }

    /// `minuta.error`: Minuta is a red !, "Reintentar", later steps wait.
    @MainActor
    static let minutesError = SnapshotState(name: "detail-minutes-error", width: windowSize.width, height: windowSize.height) {
        detail($0, .minutesError)
    }

    /// "Reintentar" on a stage with nothing to retry: the sentence under the stepper.
    @MainActor
    static let retryRefused = SnapshotState(name: "detail-retry-refused", width: windowSize.width, height: windowSize.height) {
        detail($0, .minutesError, after: { model, entry in
            model.session.commands.retryStage = { _, _, refused in refused() }
            model.session.retry(.minuta, dir: entry.dir)
        })
    }

    @MainActor
    static let noMinutes = SnapshotState(name: "detail-no-minutes", width: windowSize.width, height: windowSize.height) {
        detail($0, .noMinutes)
    }

    /// The memory send is running right now.
    @MainActor
    static let sendingMemory = SnapshotState(name: "detail-sending-memory", width: windowSize.width, height: windowSize.height) {
        detail($0, .pendingMemory) { store, folder in
            store.apply(.running(.memory, folder: folder, queued: 0))
        }
    }

    @MainActor
    static let sentMemory = SnapshotState(name: "detail-sent-memory", width: windowSize.width, height: windowSize.height) {
        detail($0, .sent)
    }

    /// Minutes and summary still owed, minutes running: two spinners.
    @MainActor
    static let inProgress = SnapshotState(name: "detail-in-progress", width: windowSize.width, height: windowSize.height) {
        detail($0, .inProgress) { store, folder in
            store.apply(.running(.minutes, folder: folder, queued: 0))
        }
    }

    /// 2+ rows selected: the detail column gives way to the bulk panel.
    @MainActor
    static let bulk = SnapshotState(name: "detail-bulk", width: windowSize.width, height: windowSize.height) { context in
        let model = context.env.makeMainWindowModel()
        SnapshotEnvironment.load(model)
        model.meetings.selection = Set(context.installed.bulkSelection.compactMap { fixture in
            model.meetings.entries.first { $0.dir.standardizedFileURL == fixture.standardizedFileURL }?.dir
        })
        return AnyView(MainView(model: model, onToggleRecording: {}, flatColumns: true))
    }

    /// "Mover a la papelera…" for three sessions, one of them sent to memory
    /// (the opt-in checkbox, default off) and one being recorded (skipped).
    /// Standalone: an offscreen window does not draw sheets.
    @MainActor
    static let trashConfirmation = SnapshotState(name: "trash-confirmation", width: 420, height: nil) { context in
        let dirs = context.installed.bulkSelection
        return AnyView(TrashConfirmationView(
            plan: TrashPlan(
                trashable: Array(dirs.prefix(2)),
                blocked: dirs.dropFirst(2).map { TrashPlan.Blocked(dir: $0, reason: .recording) },
                offersMemoryDelete: true
            ),
            label: { $0.lastPathComponent }, cancel: {}, confirm: { _ in }
        ))
    }

    /// Nothing can move right now: only the reasons and "Entendido".
    @MainActor
    static let trashConfirmationBlocked = SnapshotState(name: "trash-confirmation-blocked", width: 420, height: nil) { context in
        AnyView(TrashConfirmationView(
            plan: TrashPlan(
                trashable: [],
                blocked: context.installed.bulkSelection.prefix(2).map { TrashPlan.Blocked(dir: $0, reason: .working(.summary)) },
                offersMemoryDelete: false
            ),
            label: { $0.lastPathComponent }, cancel: {}, confirm: { _ in }
        ))
    }

    /// The five step looks side by side, on their own.
    @MainActor
    static let stepperLooks = SnapshotState(name: "stepper-looks", width: 730, height: nil) { _ in
        let steps = zip(PipelineStep.Kind.allCases, [
            PipelineStep.State.done, .active, .failed, .pending, .skipped,
        ]).map { PipelineStep(kind: $0, state: $1) }
        return AnyView(PipelineStepperView(steps: steps, onRetry: { _ in }).background(MainPalette.window))
    }
}
