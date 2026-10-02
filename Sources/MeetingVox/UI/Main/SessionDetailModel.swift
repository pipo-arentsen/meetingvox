import Foundation
import Observation

/// What one selection needs from disk, read off the main thread. Small
/// on purpose: the list already carries the markers; this is what only the
/// detail asks for.
struct SessionDetailData: Equatable, Sendable {
    let dir: URL
    /// Template ids of the manual `minuta.<id>.md` files, sorted.
    var manualMinutes: [String] = []
    /// `transcript.md` exists (what "Abrir transcripción" opens).
    var hasTranscriptMD = false
    /// Fresh memory facts for this session; nil when the integration is off.
    var facts: HindsightFacts?
    /// The Transcripción tab's lines; nil when `transcript.json` is missing or
    /// unreadable, empty for a transcript with no text.
    var transcriptLines: [TranscriptViewLine]?
    /// What `transcriptLines` was parsed from: a later read of the same file
    /// with the same stamp reuses them instead of parsing again.
    var transcriptStamp: FileStamp?
    /// `minuta.md` as text (invalid UTF-8 read lossily); nil without the file.
    var minutesText: String?
    var minutesStamp: FileStamp?
    /// The tracks the player can open: listed in meta.json, file on disk, with
    /// their length (read off the main thread, read-only). Empty without audio.
    var playbackTracks: [PlaybackTrackInfo] = []

    /// Modification time and size: what tells a rescan the big files did not change.
    struct FileStamp: Equatable, Sendable {
        let modified: Date
        let size: Int

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber
            else { return nil }
            self.modified = modified
            self.size = size.intValue
        }
    }

    /// Reads one folder. Pure over `dir` and `inputs`: no config, Keychain or
    /// home lookup of its own.
    ///
    /// - Parameter previous: the last read of this same folder. The two big
    ///   files are parsed again only when their stamp differs from the one it
    ///   recorded; the stamp is taken *before* reading, so a write racing the
    ///   read leaves an older stamp and the next rescan reads again.
    static func load(_ dir: URL, _ inputs: SessionDetailInputs, reusing previous: SessionDetailData? = nil) -> SessionDetailData {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let previous = previous?.dir == dir ? previous : nil

        let transcriptStamp = FileStamp(dir.appendingPathComponent(SessionFiles.transcriptJSON))
        var lines: [TranscriptViewLine]?
        if let previousLines = previous?.transcriptLines, transcriptStamp != nil, transcriptStamp == previous?.transcriptStamp {
            lines = previousLines
        } else if transcriptStamp != nil {
            lines = TranscriptViewLines.load(from: dir)
        }

        let minutesURL = dir.appendingPathComponent(SessionFiles.minutes)
        let minutesStamp = names.contains(SessionFiles.minutes) ? FileStamp(minutesURL) : nil
        var minutes: String?
        if let previousText = previous?.minutesText, minutesStamp != nil, minutesStamp == previous?.minutesStamp {
            minutes = previousText
        } else if minutesStamp != nil {
            minutes = readText(minutesURL)
        }

        return SessionDetailData(
            dir: dir,
            manualMinutes: names.compactMap(SessionFiles.templateID(ofMinutesFile:)).sorted(),
            hasTranscriptMD: names.contains(SessionFiles.transcriptMD),
            facts: inputs.options.map { HindsightFacts.read(dir, $0) },
            transcriptLines: lines, transcriptStamp: transcriptStamp,
            minutesText: minutes, minutesStamp: minutesStamp,
            playbackTracks: SessionTracks.info(in: dir)
        )
    }
}

private func readText(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

/// The main-actor state a detail needs (config, Keychain attributes), taken
/// once per list reload — not per selection — and handed to every off-main
/// read. It also answers window-level questions the rows share (do summaries
/// apply, why minutes cannot run), so they never wait for a row's load.
struct SessionDetailInputs: Sendable {
    /// nil = the memory integration is off: no facts are read.
    var options: HindsightFacts.Options?
    var summaryApplies: Bool
    var minutesUnavailableReason: String?
    /// The configured minutes template, where the Minuta tab's picker starts.
    var defaultTemplateID: String?

    static let none = SessionDetailInputs(options: nil, summaryApplies: false, minutesUnavailableReason: nil)
}

/// What the toolbar and the stepper do, wired by `AppController` (real
/// coordinators) or left as no-ops (tests, snapshots).
struct DetailCommands {
    var openFolder: (URL) -> Void = { _ in }
    /// Opens a file with its default app (the transcript, a manual minuta).
    var openFile: (URL) -> Void = { _ in }
    var applyGlossary: (URL) -> Void = { _ in }
    /// "Regenerar minuta con ▸ <plantilla>".
    var regenerate: (_ dir: URL, _ templateID: String) -> Void = { _, _ in }
    /// "Generar minuta con… ▸ <plantilla>" (a manual `minuta.<id>.md`).
    var generateManual: (_ dir: URL, _ templateID: String) -> Void = { _, _ in }
    /// A failed step's "Reintentar" and the menu's "Reintentar minuta".
    /// `refused` is called if the stage had nothing to retry, so the detail
    /// can say so.
    var retryStage: (_ stage: Notice.Stage, _ dir: URL, _ refused: @escaping @MainActor @Sendable () -> Void) -> Void =
        { _, _, _ in }
    /// Already re-checked against the disk (`SessionDetailModel.chooseMemory`).
    var sendToMemory: (_ dir: URL, _ action: HindsightStatus.Action, _ bank: String?) -> Void = { _, _, _ in }
    var setMemorySkipped: (_ dir: URL, _ skipped: Bool) -> Void = { _, _ in }
    /// The Minuta tab's "Generar minuta": a user-requested job
    /// (`MinutesCoordinator.generateFromWindow`), no marker and no hook.
    /// Says whether the coordinator took it.
    var generateFromWindow: (URL) async -> Bool = { _ in true }
    /// The session's template choice in meta.json (`minutes_template`), and
    /// its setter (nil = no choice): the job reads the choice there. They only
    /// touch the given folder.
    /// "Quitar evento del calendario": removes the key from meta.json (throws
    /// when it cannot), then `reindex` asks for `indice.md` to be regenerated.
    var removeCalendarEvent: (_ dir: URL) throws -> Void = { try SessionFiles.setCalendarEvent(nil, in: $0) }
    var reindex: () -> Void = {}
    var minutesTemplate: (_ dir: URL) -> String? = { SessionFiles.chosenMinutesTemplate(in: $0) }
    var setMinutesTemplate: (_ dir: URL, _ templateID: String?) throws -> Void = { dir, id in
        try SessionFiles.setChosenMinutesTemplate(id, in: dir)
    }
}

/// The selected session's detail: its off-main data, generation-guarded (and
/// the superseded read cancelled) so a slow load for the previous row never
/// overwrites the current one, and the toolbar's actions, including the
/// live re-check before any memory send.
///
/// Every action takes the folder of the row being drawn instead of reading
/// `selected`: a click always acts on what the user was looking at, even in the
/// gap before a selection change reaches this model.
@MainActor
@Observable
final class SessionDetailModel {
    /// - Parameter previous: the data already held for the same folder (nil for
    ///   another one), so a rescan can skip what did not change.
    typealias Load = @Sendable (URL, SessionDetailInputs, SessionDetailData?) async -> SessionDetailData

    /// A memory send that never reports back stops blocking after this long.
    static let inFlightTimeout: TimeInterval = 20

    /// The folder the detail is for.
    private(set) var selected: URL?
    /// Data for `selected`; nil while it loads (and after a change of
    /// session), so a row never shows another session's data.
    private(set) var data: SessionDetailData?
    /// The config/Keychain snapshot of the last list reload.
    private(set) var inputs: SessionDetailInputs = .none
    /// A sentence under the stepper (a refused retry, a stale memory action),
    /// for the folder it is about.
    private(set) var notice: (dir: URL, message: String)?
    /// Sessions with a memory send dispatched and not yet reported (folder →
    /// when), so a second click cannot dispatch it again.
    private var memoryInFlight: [URL: Date] = [:]

    @ObservationIgnored var commands = DetailCommands()
    /// The session's memory status read from disk right now (`readCheap` +
    /// derive), for the re-check.
    @ObservationIgnored var liveMemoryStatus: (URL) -> HindsightStatus? = { _ in nil }
    /// The selected session's data changed: loaded, reloaded, or cleared (nil)
    /// because another session was selected. The player follows it.
    @ObservationIgnored var onDataChanged: (SessionDetailData?) -> Void = { _ in }
    /// A refused (stale) action: the list should rescan too.
    @ObservationIgnored var onListNeedsReload: () -> Void = {}
    /// "Mover a la papelera…" on this folder: the window model shows the sheet.
    @ObservationIgnored var onRequestTrash: (URL) -> Void = { _ in }
    /// What the session's minutes markers say right now, read from disk, for
    /// the re-check before "Generar minuta".
    @ObservationIgnored var minutesRoute: (URL) -> MinutesRequestRoute = { MinutesRequestRoute.decide(dir: $0) }

    @ObservationIgnored private let makeInputs: () -> SessionDetailInputs
    @ObservationIgnored private let load: Load
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inputsTaken = false
    /// The read in flight; a newer one cancels it. Tests await it.
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?

    init(
        inputs: @escaping () -> SessionDetailInputs = { .none },
        load: @escaping Load = { dir, inputs, previous in SessionDetailData.load(dir, inputs, reusing: previous) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.makeInputs = inputs
        self.load = load
        self.now = now
    }

    func data(for dir: URL) -> SessionDetailData? {
        data?.dir == dir ? data : nil
    }

    // MARK: - Inputs

    /// Take the config/Keychain snapshot again (once per list reload).
    func refreshInputs() {
        inputs = makeInputs()
        inputsTaken = true
    }

    // MARK: - Loading

    /// Show `dir` (nil = nothing). A different session clears the old data
    /// and any message at once; the same one keeps them while it refreshes.
    /// Whatever was loading before is superseded and cancelled.
    @discardableResult
    func select(_ dir: URL?) -> Task<Void, Never> {
        if dir != selected {
            selected = dir
            let hadData = data != nil
            data = nil
            notice = nil
            if hadData { onDataChanged(nil) }
        }
        guard let dir else {
            generation += 1
            loadTask?.cancel()
            loadTask = nil
            return Task {}
        }
        return startLoad(dir)
    }

    /// Read the selected session again (a marker changed, a job finished).
    @discardableResult
    func reload() -> Task<Void, Never> {
        guard let selected else { return Task {} }
        return startLoad(selected)
    }

    private func startLoad(_ dir: URL) -> Task<Void, Never> {
        if !inputsTaken { refreshInputs() }
        generation += 1
        let expected = generation
        let snapshot = inputs
        let previous = data?.dir == dir ? data : nil
        let load = self.load
        loadTask?.cancel()
        let task = Task {
            let result = await load(dir, snapshot, previous)
            guard !Task.isCancelled, expected == self.generation, self.selected == dir else { return }
            self.data = result
            self.onDataChanged(result)
        }
        loadTask = task
        return task
    }

    // MARK: - Messages

    func notice(for dir: URL) -> String? {
        notice?.dir == dir ? notice?.message : nil
    }

    func dismissNotice() { notice = nil }

    private func say(_ message: String, about dir: URL) { notice = (dir, message) }

    // MARK: - Memory

    func isMemoryInFlight(_ dir: URL) -> Bool {
        guard let since = memoryInFlight[dir] else { return false }
        return now().timeIntervalSince(since) < Self.inFlightTimeout
    }

    /// Hindsight reported something (sent, failed, sending): whatever was in
    /// flight has an answer now.
    func memoryStatusChanged() { memoryInFlight = [:] }

    /// A send, resend or retry from the memory button or the stepper. The
    /// disk decides: if the session no longer offers `action` (sent since the
    /// menu opened, omitted, integration off) nothing is sent and the UI
    /// re-reads instead. One send per session at a time.
    func chooseMemory(_ action: HindsightStatus.Action, bank: String?, shownAs shown: HindsightStatus?, dir: URL) {
        guard !isMemoryInFlight(dir) else { return }
        guard action.isStillOffered(by: liveMemoryStatus(dir), shownAs: shown) else {
            FileHandle.standardError.write(Data(
                "detail: memory \(action) no longer applies to \(dir.lastPathComponent); refreshing\n".utf8
            ))
            say(RetryRefusal.message(for: .memory), about: dir)
            if selected == dir { reload() }
            onListNeedsReload()
            return
        }
        memoryInFlight[dir] = now()
        commands.sendToMemory(dir, action, bank)
    }

    /// "No enviar a memoria".
    func skipMemory(dir: URL) {
        commands.setMemorySkipped(dir, true)
    }

    // MARK: - The rest of the toolbar and the stepper

    func perform(_ kind: DetailActions.OverflowItem.Kind, dir: URL) {
        switch kind {
        case .openFolder: commands.openFolder(dir)
        case .openTranscript: commands.openFile(dir.appendingPathComponent(SessionFiles.transcriptMD))
        case .openMinutes: commands.openFile(dir.appendingPathComponent(SessionFiles.minutes))
        case .applyGlossary: commands.applyGlossary(dir)
        case .openManualMinutes(let id): commands.openFile(dir.appendingPathComponent(SessionFiles.minutes(templateID: id)))
        case .unlinkCalendar: unlinkCalendar(dir: dir)
        case .moveToTrash: onRequestTrash(dir)
        }
    }

    /// "Quitar evento del calendario": no calendar access, no re-matching.
    /// Titles revert on the reload this triggers; the index is regenerated.
    func unlinkCalendar(dir: URL) {
        do {
            try commands.removeCalendarEvent(dir)
        } catch {
            FileHandle.standardError.write(Data("detail: could not unlink calendar event: \(error)\n".utf8))
            say(Textos.Sesiones.quitarEventoFallo, about: dir)
            return
        }
        commands.reindex()
        if selected == dir { reload() }
        onListNeedsReload()
    }

    func regenerate(templateID: String, dir: URL) {
        commands.regenerate(dir, templateID)
    }

    func generate(templateID: String, dir: URL) {
        commands.generateManual(dir, templateID)
    }

    /// A failed step's "Reintentar" (and "Reintentar minuta"). A stage with
    /// nothing to retry leaves a sentence saying why.
    func retry(_ kind: PipelineStep.Kind, dir: URL) {
        notice = nil
        switch kind {
        case .grabada: break
        case .transcrita: retryStage(.transcription, dir)
        case .minuta: retryStage(.minutes, dir)
        case .resumen: retryStage(.summary, dir)
        case .memoria: chooseMemory(.retry, bank: nil, shownAs: liveMemoryStatus(dir), dir: dir)
        }
    }

    /// The Minuta tab's "Generar minuta". The disk decides: only a session with
    /// a transcript and nothing owed may start a user-requested job (minutes
    /// that appeared, or an automatic request that became owed since the tab
    /// was drawn, would otherwise be raced). The chosen template is saved in
    /// meta.json first, then the job asked for; if the save fails nothing is
    /// requested, since the job would silently use another template. If the
    /// coordinator then refuses the job, the earlier choice (or none) is put
    /// back, so a pick that never ran does not colour a later automatic job.
    ///
    /// - Returns: the request in flight; tests await it.
    @discardableResult
    func generateMinutes(templateID: String, dir: URL) -> Task<Void, Never> {
        notice = nil
        guard minutesRoute(dir) == .generate else {
            minutesChanged(dir)
            return Task {}
        }
        let earlier = commands.minutesTemplate(dir)
        do {
            try commands.setMinutesTemplate(dir, templateID)
        } catch {
            FileHandle.standardError.write(Data(
                "detail: could not save the minutes template for \(dir.lastPathComponent): \(error)\n".utf8
            ))
            say(Textos.Principal.plantillaNoGuardada, about: dir)
            return Task {}
        }
        return Task { [weak self] in
            guard let self else { return }
            if await self.commands.generateFromWindow(dir) { return }
            do {
                try self.commands.setMinutesTemplate(dir, earlier)
            } catch {
                FileHandle.standardError.write(Data(
                    "detail: could not restore the minutes template for \(dir.lastPathComponent): \(error)\n".utf8
                ))
            }
            self.minutesChanged(dir)
        }
    }

    /// The minutes state moved under the tab: say so and re-read.
    private func minutesChanged(_ dir: URL) {
        FileHandle.standardError.write(Data(
            "detail: generating minutes no longer applies to \(dir.lastPathComponent); refreshing\n".utf8
        ))
        say(Textos.Principal.minutaCambio, about: dir)
        if selected == dir { reload() }
        onListNeedsReload()
    }

    private func retryStage(_ stage: Notice.Stage, _ dir: URL) {
        commands.retryStage(stage, dir) { [weak self] in
            self?.say(RetryRefusal.message(for: stage), about: dir)
        }
    }
}
