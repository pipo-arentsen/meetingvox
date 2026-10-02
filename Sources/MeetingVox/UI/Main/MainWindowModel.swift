import Foundation
import Observation

/// The main window's composition root: `MeetingsModel` stays the list engine
/// (filters, 30-day paging, memory facts, classify), and this adds what the
/// window itself owns — the sidebar selection, the live pipeline overlay, and
/// the pure derivations the views draw (sections, counts, pills, the record
/// button, the detail mode).
///
/// It touches no defaults: the list model, the store, the calendar and the
/// clock all arrive by injection, so tests and the headless snapshots run it
/// over a temp root.
@MainActor
@Observable
final class MainWindowModel {
    let meetings: MeetingsModel
    let store: PipelineStatusStore
    /// The selected session's off-main data and the toolbar's actions.
    let session: SessionDetailModel
    /// Biblioteca's editors (Plantillas, Glosario).
    let library: LibraryModel
    /// The Tareas page over the list engine's entries.
    let tasks: TasksPageModel
    /// The player of the selected session (Transcripción tab).
    let playback: PlaybackController

    /// The sidebar entry shown. Reuniones and the ámbito entries also set the
    /// list's ámbito filter; the Tareas and Biblioteca pages leave it as it was.
    var sidebar: SidebarItem = .reuniones {
        didSet {
            // Another page: the player's controls are gone, so is its audio.
            playback.pause()
            library.refresh(for: sidebar)
            guard let filter = sidebar.ambitoFilter, filter != meetings.ambitoFilter else { return }
            meetings.ambitoFilter = filter
        }
    }

    /// The tab under the stepper. Kept while moving between sessions; opening
    /// a session from a notice may set it (`focus(on:tab:)`).
    var tab: DetailTab = .resumen {
        // The jump marker belongs to the Transcripción tab it was set for.
        didSet {
            guard tab != .transcripcion else { return }
            transcriptTarget = nil
            // The player's controls live on the Transcripción tab only.
            playback.pause()
        }
    }

    /// The transcript line a search hit opened: the tab scrolls to it and
    /// draws it as the current line. Cleared on leaving the tab and on `focus`.
    var transcriptTarget: TranscriptTarget?
    @ObservationIgnored private var transcriptTargetNonce = 0

    /// The window is open. A finished job only rescans then; a closed window
    /// shouldn't pay for scans nobody sees. Closing also drops a rescan that
    /// was waiting for its delay.
    @ObservationIgnored var isActive = false {
        didSet {
            if !isActive {
                debouncer.cancel()
                meetings.clearFullText()
                playback.unload()
            }
        }
    }

    @ObservationIgnored private let calendar: Calendar
    /// The zone the rows' times are shown in (the calendar's).
    var timeZone: TimeZone { calendar.timeZone }
    @ObservationIgnored private let now: @Sendable () -> Date

    /// Bursts (a stage ending, a notification, a memory status) wait here and
    /// become one scan.
    @ObservationIgnored private let reloadScheduler: ReloadScheduler
    @ObservationIgnored private lazy var debouncer = ReloadDebouncer(scheduler: reloadScheduler) { [weak self] in
        guard let self, self.isActive else { return }
        self.rescan()
    }

    init(
        meetings: MeetingsModel, store: PipelineStatusStore,
        calendar: Calendar, now: @escaping @Sendable () -> Date,
        reloadScheduler: ReloadScheduler = .live, session: SessionDetailModel = SessionDetailModel(),
        library: LibraryModel, playback: PlaybackController? = nil
    ) {
        self.meetings = meetings
        self.store = store
        self.session = session
        self.library = library
        self.tasks = TasksPageModel(meetings: meetings)
        // The gate reads the store live, so a recording already running when
        // this (lazily built) model appears is seen at once.
        self.playback = playback ?? PlaybackController.live(
            recordingState: { [store] in (store.recordingDir, store.recordingExcludesSelf) }
        )
        self.calendar = calendar
        self.now = now
        self.reloadScheduler = reloadScheduler
        // A stage leaving a session, or the recording becoming a session: the
        // disk has probably changed. The window, not the store, decides
        // whether that is worth a scan.
        store.onFinished = { [weak self] _ in self?.jobFinished() }
        // The store has one slot per callback and this model is its only
        // subscriber: the stop keeps the rescan and also re-enables the player.
        store.onRecordingStopped = { [weak self] _ in
            self?.jobFinished()
            self?.playback.recordingChanged(dir: nil, excludesSelf: false)
        }
        store.onRecordingStarted = { [weak self] dir in
            guard let self else { return }
            self.playback.recordingChanged(dir: dir, excludesSelf: self.store.recordingExcludesSelf)
        }
        // The player follows the detail's data: a session's tracks and lines
        // when they load, nothing once another session replaces them.
        session.onDataChanged = { [weak self] data in
            guard let self else { return }
            if let data {
                self.playback.show(dir: data.dir, tracks: data.playbackTracks, lines: data.transcriptLines ?? [])
            } else {
                self.playback.unload()
            }
        }
        // A refused memory action: rescan so the list says what the disk says.
        session.onListNeedsReload = { [weak self] in self?.reload() }
        session.onRequestTrash = { [weak self] dir in self?.requestTrash([dir]) }
        // A task's meeting link: that session, on the Resumen tab.
        tasks.onOpen = { [weak self] dir in self?.focus(on: dir, tab: .resumen) }
    }

    // MARK: - Loading

    /// Rescan now (list, facts, config snapshot); it covers whatever
    /// `scheduleReload` had pending. Tests observe `reloadCount`.
    @discardableResult
    func reload() -> Task<Void, Never> {
        debouncer.cancel()
        return rescan()
    }

    /// The list rescans, the config/Keychain snapshot the detail shares is
    /// taken once, and the open session's data is read again: a job that just
    /// wrote `minuta.<id>.md`, or an export that just answered, shows up in its
    /// header and toolbar without reselecting.
    @discardableResult
    private func rescan() -> Task<Void, Never> {
        session.refreshInputs()
        session.reload()
        return meetings.reload()
    }

    /// Rescan after a short quiet period; repeated calls become one scan.
    func scheduleReload() { debouncer.request() }

    var reloadCount: Int { meetings.reloadCount }

    /// Hindsight reported an outcome (sent, failed, sending): a send in flight
    /// has its answer, and the rows re-read what the disk now says.
    func hindsightStatusChanged() {
        session.memoryStatusChanged()
        scheduleReload()
    }

    private func jobFinished() {
        guard isActive else { return }
        scheduleReload()
    }

    // MARK: - Opening a session

    /// "Abrir" / "Ver reunión" / "Última": show `dir` selected alone (any
    /// multi-selection is dropped), scrolled into view, with whatever would
    /// hide it cleared — search, client, tipo, rango, an ámbito entry, the
    /// Tareas or Biblioteca page, the 30-day window. `tab` picks the tab; nil keeps
    /// the current one. A folder that does not exist changes nothing (the
    /// caller only brings the window up); one recorded since the last scan is
    /// selected when the next scan finds it.
    func focus(on dir: URL, tab: DetailTab? = nil) {
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        sidebar = .reuniones
        transcriptTarget = nil
        meetings.focus(on: dir)
        if let tab { self.tab = tab }
    }

    /// A snippet tapped in the list: that session, selected alone, on the tab
    /// the text came from — Transcripción scrolled to the line, or Minuta.
    /// Unlike `focus(on:)` the query and filters stay, so "back to the list"
    /// is where the user left it.
    func openSearchHit(_ dir: URL, _ hit: SearchHit) {
        meetings.selection = [dir]
        switch hit.source {
        case .transcript:
            tab = .transcripcion
            transcriptTargetNonce += 1
            transcriptTarget = TranscriptTarget(dir: dir, lineID: hit.lineID, nonce: transcriptTargetNonce)
        case .minutes:
            tab = .minuta
            transcriptTarget = nil
        }
    }

    /// Which tap produced the current target (changes on every tap, even on the same line).
    func transcriptTargetNonce(for dir: URL) -> Int {
        transcriptTarget?.dir == dir ? transcriptTarget?.nonce ?? 0 : 0
    }

    /// The line to mark in `dir`'s transcript, if a hit targeted it.
    func transcriptLineTarget(for dir: URL) -> Int? {
        transcriptTarget?.dir == dir ? transcriptTarget?.lineID : nil
    }

    // MARK: - Sidebar

    /// Over **every** session, not the current filter or page.
    var counts: SidebarCounts { SidebarCounts(meetings.entries) }

    // MARK: - List

    var sections: [ListSection] {
        ListSections.build(meetings.filtered, now: now(), calendar: calendar)
    }

    /// "N de M reuniones".
    var footer: String { meetings.footer }

    var emptyState: ListEmptyState? {
        ListEmptyState.of(hasLoaded: meetings.hasLoaded, total: meetings.entries.count, shown: meetings.filtered.count)
    }

    /// The row's single status chip, or nil.
    func pill(for entry: MeetingEntry) -> StatusPill? {
        StatusPill.derive(
            entry: entry, memory: meetings.hindsightStatus(for: entry),
            live: store.live(for: entry.dir.lastPathComponent), recordingDir: store.recordingDir
        )
    }

    // MARK: - Selection

    /// The selected rows the list shows now — what the bulk panel acts on.
    var bulkTargets: [URL] { meetings.selectedVisible }

    /// What the detail column shows, with the data each case needs: the
    /// session for one row, the count for a bulk selection. Built from the
    /// visible selection, so a row the filter hides never counts.
    var detail: DetailSelection {
        let targets = bulkTargets
        switch DetailMode.of(selectedVisible: targets.count) {
        case .none:
            return .none
        case .single:
            // `selectedVisible` is drawn from `entries`, so the match exists.
            let entry = meetings.entries.first { $0.dir == targets[0] }
            return entry.map(DetailSelection.single) ?? .none
        case .bulk(let count):
            return .bulk(count: count)
        }
    }

    /// "Clasificar como" over the visible selection; nil = "Sin clasificar".
    func classifySelected(as ambito: Ambito?) {
        meetings.classify(bulkTargets, as: ambito)
    }

    // MARK: - Session detail

    /// The header's text and chips.
    func header(for entry: MeetingEntry) -> DetailHeader {
        DetailHeader.make(
            entry: entry, type: MeetingType.of(entry, knownTemplateIDs: Set(meetings.templates.map(\.id))),
            templates: meetings.templates, timeZone: timeZone
        )
    }

    /// The selected session's memory status from its fresh read, else the
    /// list's (facts read at the last scan); nil with the integration off.
    func memoryStatus(for entry: MeetingEntry) -> HindsightStatus? {
        guard let data = session.data(for: entry.dir) else { return meetings.hindsightStatus(for: entry) }
        return meetings.hindsightStatus(from: data.facts)
    }

    /// Grabada, Transcrita, Minuta, Resumen, Memoria: the markers, with the
    /// live store overlaying only "active".
    func steps(for entry: MeetingEntry) -> [PipelineStep] {
        let folder = entry.dir.lastPathComponent
        return PipelineStepper.derive(
            entry: entry, memory: memoryStatus(for: entry), live: store.live(for: folder),
            recording: store.recordingDir == entry.dir,
            summaryApplies: session.inputs.summaryApplies
        )
    }

    /// The toolbar's menus.
    func actions(for entry: MeetingEntry) -> DetailActions {
        let data = session.data(for: entry.dir)
        return DetailActions.build(DetailActions.Input(
            hasTranscript: entry.hasTranscript,
            // Until the row's data arrives the transcript marker stands in, so
            // the menu does not flip from disabled to enabled.
            hasTranscriptMD: data?.hasTranscriptMD ?? entry.hasTranscript,
            hasMinutes: entry.hasMinutes,
            minutesOwed: entry.minutesPending || entry.minutesFailed,
            manualMinutes: data?.manualMinutes ?? [], templates: meetings.templates,
            minutesUnavailableReason: session.inputs.minutesUnavailableReason,
            memory: memoryStatus(for: entry), memoryInFlight: session.isMemoryInFlight(entry.dir),
            defaultBank: meetings.defaultBankSnapshot, otherBanks: meetings.otherBanksSnapshot,
            hasCalendarEvent: entry.calendarEvent != nil
        ))
    }

    /// The header's ámbito chip.
    func classify(_ entry: MeetingEntry, as ambito: Ambito?) {
        meetings.classify([entry.dir], as: ambito)
    }

    // MARK: - Mover a la papelera

    /// What the confirmation sheet shows: the plan for the sessions asked for.
    struct TrashRequest: Equatable {
        let plan: TrashPlan
    }

    /// The real work behind "Mover a la papelera…", wired by `AppController`.
    /// The defaults are inert on purpose (nothing reaches the Trash or the
    /// server from a test or a snapshot): memory deletion fails, moving throws.
    struct TrashEffects {
        var deleteFromMemory: (URL) async -> HindsightCoordinator.DeleteResult = { _ in .failed("not wired") }
        /// `FileManager.trashItem`. Never `removeItem`.
        var trash: (URL) throws -> Void = { _ in throw CocoaError(.fileWriteUnknown) }
        /// The session has a v2 `hindsight.json`.
        var isInMemory: (URL) -> Bool = { HindsightFacts.readSent($0) != nil }
        /// Work still owed: the on-disk requests (`TrashPlan.hasPendingWorkOnDisk`),
        /// which is all the default knows; `AppController` adds the
        /// transcription queue (async: it asks the coordinator actor).
        var hasPendingWork: (URL) async -> Bool = { TrashPlan.hasPendingWorkOnDisk($0) }
    }

    @ObservationIgnored var trashEffects = TrashEffects()
    /// The sheet is up for this plan; nil = none.
    private(set) var trashRequest: TrashRequest?
    /// The plan being computed (the owed-work check is async); tests await it.
    @ObservationIgnored private(set) var trashPlanning: Task<Void, Never>?
    /// A sentence after a run that kept a folder (memory delete or move failed).
    private(set) var trashProblem: String?

    /// "Mover a la papelera…": plan the sessions and show the sheet. Nothing
    /// moves until `confirmTrash`. The sheet appears once the owed-work check
    /// (which asks the transcription actor) has answered.
    @discardableResult
    func requestTrash(_ dirs: [URL]) -> Task<Void, Never> {
        trashPlanning?.cancel()
        guard !dirs.isEmpty else { return Task {} }
        let task = Task { [weak self] in
            guard let self else { return }
            let plan = await trashPlan(dirs)
            guard !Task.isCancelled else { return }
            trashRequest = TrashRequest(plan: plan)
        }
        trashPlanning = task
        return task
    }

    func cancelTrash() {
        trashPlanning?.cancel()
        trashRequest = nil
    }

    /// The sheet's name for a session: its summary title, else the folder.
    func trashLabel(for dir: URL) -> String {
        let title = meetings.entries.first { $0.dir == dir }?.summary?.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.flatMap { $0.isEmpty ? nil : $0 } ?? dir.lastPathComponent
    }

    func dismissTrashProblem() { trashProblem = nil }

    /// Rules over the live state: recording folder, working stages and work
    /// still owed on disk.
    private func trashPlan(_ dirs: [URL]) async -> TrashPlan {
        // Async facts first, so `TrashPlan.make` stays pure.
        var pending = Set<String>()
        for dir in dirs where await trashEffects.hasPendingWork(dir) {
            pending.insert(dir.standardizedFileURL.path)
        }
        return TrashPlan.make(
            sessions: dirs, recordingDir: store.recordingDir, liveOverlay: { [store] in store.live(for: $0) },
            isInMemory: trashEffects.isInMemory, memoryEnabled: session.inputs.options != nil,
            hasPendingWork: { pending.contains($0.standardizedFileURL.path) }
        )
    }

    /// Runs the confirmed plan: each folder is re-checked, optionally deleted
    /// from memory first (a failure keeps it), then moved to the Trash. The
    /// player lets go of a folder before it moves; rows, selection and the
    /// index follow what actually left.
    ///
    /// - Parameter deleteFromMemory: the sheet's checkbox; ignored unless the
    ///   plan offered it.
    /// - Returns: the run in flight; tests await it.
    @discardableResult
    func confirmTrash(deleteFromMemory: Bool) -> Task<Void, Never> {
        guard let request = trashRequest else { return Task {} }
        trashRequest = nil
        let plan = request.plan
        if let shown = playback.dir, plan.trashable.contains(shown) { playback.unload() }
        let effects = trashEffects
        let runner = TrashRunner(
            deleteFromMemory: effects.deleteFromMemory, trash: effects.trash,
            recheck: { [weak self] dir in await self?.trashPlan([dir]).blocked.first?.reason }
        )
        return Task {
            let report = await runner.run(plan: plan, deleteFromMemory: deleteFromMemory && plan.offersMemoryDelete)
            self.finishTrash(report)
        }
    }

    private func finishTrash(_ report: TrashReport) {
        if let selected = session.selected, report.trashed.contains(selected) {
            session.select(nil)
            playback.unload()
        }
        if !report.trashed.isEmpty {
            meetings.remove(report.trashed)
            // `indice.md` and the open lists (Tareas included) follow.
            session.commands.reindex()
            reload()
        }
        var lines: [String] = []
        if !report.memoryFailed.isEmpty { lines.append(Textos.Papelera.memoriaFallo) }
        if !report.trashFailed.isEmpty { lines.append(Textos.Papelera.noSePudoMover) }
        trashProblem = lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Title strip

    var recordButton: RecordButtonState { RecordButtonState.of(store.recording) }
}
