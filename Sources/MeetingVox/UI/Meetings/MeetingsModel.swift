import Foundation
import Observation

/// The list engine behind the main window: read-only, refreshed from disk
/// (`MeetingIndex.scan`) on `reload()` (the window reloads on
/// `.meetingVoxMeetingIndexDidChange` / `.meetingVoxHindsightStatusDidChange`
/// / `.meetingVoxConfigDidChange`); shows the last 30 days (more on
/// "Meses anteriores") or, while searching, every session; memory
/// facts are read only for what it shows; filters by search, client, ámbito,
/// type and range (any of the first four searches every session).
@MainActor
@Observable
final class MeetingsModel {
    private(set) var entries: [MeetingEntry] = [] {
        didSet { entriesRevision += 1 }
    }
    /// Bumps on every change to `entries`: a cheap key for views that cache a
    /// derivation of the whole array (the Tareas page).
    private(set) var entriesRevision = 0
    /// The first scan has published (an empty `entries` before that means
    /// "not known yet", after it "no sessions"). Never goes back to false.
    private(set) var hasLoaded = false
    /// Memory facts for the sessions shown so far (the loaded window and any
    /// search results), keyed by folder.
    private(set) var facts: [URL: HindsightFacts] = [:]
    var query = "" {
        didSet {
            loadMissingFacts()
            scheduleSearch()
        }
    }
    /// What the full-text index answered, tagged with the query it answered:
    /// used only while `query` is still that query (a stale answer never
    /// shows). nil before the first answer and after a blank query or a close.
    private(set) var searchAnswer: SearchAnswer?

    struct SearchAnswer: Equatable {
        let query: String
        let result: FullTextIndex.Result
    }
    /// nil = every client.
    var selectedClient: String? {
        didSet { loadMissingFacts() }
    }
    var range: MeetingFilter.Range = .any {
        didSet { loadMissingFacts() }
    }
    var ambitoFilter: AmbitoFilter = .all {
        didSet { loadMissingFacts() }
    }
    /// nil = every type.
    var typeFilter: MeetingType? {
        didSet { loadMissingFacts() }
    }
    /// `listTemplates()` as of the last `reload()`: the type labels and which
    /// template ids still exist.
    private(set) var templates: [MinutesTemplate] = []
    /// Months loaded beyond the first 30 days; back to 0 when the window closes.
    private(set) var extraMonths = 0

    /// Rows selected in the list (⌘/⇧-click). Selecting does nothing by
    /// itself; it only feeds "Clasificar como".
    var selection: Set<URL> = []

    /// The row the list should scroll to (set by `focus(on:)`); the view calls
    /// `consumeScrollTarget()` once it has scrolled.
    private(set) var scrollTarget: URL?

    /// The selected rows the list shows now, in list order — what
    /// "Clasificar como" applies to: a row hidden by a filter or the 30-day
    /// window is never changed behind the user's back.
    var selectedVisible: [URL] { filtered.map(\.dir).filter(selection.contains) }

    /// Templates for the type labels and filter (read once per `reload()`);
    /// wired by `AppController`.
    var listTemplates: () -> [MinutesTemplate] = { [] }
    /// Banks other than the default (`HindsightBankList.others`); wired by
    /// `AppController`. Read once per `reload()` into `otherBanksSnapshot`
    /// rather than per row.
    var otherBanks: () -> [String] = { [] }
    /// Snapshot of `otherBanks()` taken by the last `reload()`, reused for
    /// every row instead of calling the closure (and re-parsing config.json)
    /// again per row.
    private(set) var otherBanksSnapshot: [String] = []
    /// The default bank (`HindsightBankList.defaultBank`); wired by
    /// `AppController`. Read once per `reload()` into `defaultBankSnapshot`,
    /// same reasoning as `otherBanksSnapshot`.
    var defaultBank: () -> String? = { nil }
    /// Snapshot of `defaultBank()` taken by the last `reload()`.
    private(set) var defaultBankSnapshot: String?

    /// Full-text search over transcripts and minutes: in memory, off
    /// the main thread, refreshed after every scan, cleared when the window closes.
    @ObservationIgnored private let fullText: FullTextIndex
    @ObservationIgnored private let searchScheduler: ReloadScheduler
    /// Typing waits this long for the next keystroke before the index is asked.
    @ObservationIgnored private lazy var searchDebouncer = ReloadDebouncer(
        delay: MeetingsModel.searchDelay, scheduler: searchScheduler
    ) { [weak self] in self?.runSearch() }
    static let searchDelay: TimeInterval = 0.15
    /// The last index refresh/clear (chained, so they never reorder) and the
    /// last search; tests await them.
    @ObservationIgnored private(set) var indexTask: Task<Void, Never>?
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    /// An older search is dropped when it returns.
    @ObservationIgnored private var searchGeneration = 0
    /// The index is built lazily: only once a query is non-empty, and only
    /// while one is (a window that never searches never pays for it).
    /// False again from `clearFullText()`: a scan already in flight when the
    /// window closed must not rebuild the index.
    @ObservationIgnored private var indexActive = false

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let index: MeetingIndex
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let config: () -> ConfigValues
    /// `HindsightCoordinator.authPaused`, read once per `reload()` into
    /// `authPausedSnapshot` — see `MeetingVoxCommand.swift`'s `hindsightAuthPaused`.
    @ObservationIgnored private let hindsightAuthPaused: () -> Bool
    /// A `focus(on:)` waiting for a scan to publish (`entries` unknown yet).
    @ObservationIgnored private var pendingFocus: URL?
    /// A stale scan (superseded by a newer `reload()`) is dropped on return.
    @ObservationIgnored private var generation = 0
    /// A `reload()` scan is in flight (set on start, cleared when the
    /// current generation publishes). `classify` uses it to supersede a scan
    /// that read meta.json before its writes.
    @ObservationIgnored private var reloading = false
    /// How many times `reload()` was called. Tests observe it instead of
    /// waiting to see whether a reload happened.
    @ObservationIgnored private(set) var reloadCount = 0
    /// The last facts read (or reload); tests await it.
    @ObservationIgnored private(set) var factsTask: Task<Void, Never>?
    /// `HindsightStatus.Settings`/`hindsightAuthPaused()` snapshot taken by
    /// the last `reload()`: every row's
    /// `hindsightStatus(for:)` reuses it instead of re-parsing config.json
    /// and re-reading auth state on every call. `nil` before the first
    /// reload completes, same as `facts` being empty then.
    @ObservationIgnored private var settingsSnapshot: HindsightStatus.Settings?
    @ObservationIgnored private var authPausedSnapshot = false

    /// Where a classify announces itself (`.meetingVoxMeetingIndexDidChange`,
    /// sent by this model) so any other window's model reloads.
    @ObservationIgnored private let notifications: NotificationCenter

    init(
        root: URL, index: MeetingIndex = MeetingIndex(), calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        config: @escaping () -> ConfigValues,
        hindsightAuthPaused: @escaping () -> Bool = { false },
        notifications: NotificationCenter = .default,
        fullText: FullTextIndex = FullTextIndex(), searchScheduler: ReloadScheduler = .live
    ) {
        self.fullText = fullText
        self.searchScheduler = searchScheduler
        self.notifications = notifications
        self.root = root
        self.index = index
        self.calendar = calendar
        self.now = now
        self.config = config
        self.hindsightAuthPaused = hindsightAuthPaused
    }

    var cutoff: Date { MeetingWindow.cutoff(extraMonths: extraMonths, now: now(), calendar: calendar) }

    /// What the list shows: the loaded window (or every session while
    /// searching) through the search, client and range filters — "Todas"
    /// (`.any`) respects the loaded window. Memory facts are read for
    /// exactly these rows.
    var filtered: [MeetingEntry] { visible(in: entries) }

    private func visible(in entries: [MeetingEntry]) -> [MeetingEntry] {
        MeetingFilter.apply(
            MeetingWindow.candidates(
                entries, query: query, client: selectedClient, ambito: ambitoFilter, type: typeFilter, cutoff: cutoff
            ),
            query: query, client: selectedClient, range: range,
            ambito: ambitoFilter, type: typeFilter, knownTemplateIDs: knownTemplateIDs,
            fullTextMatches: currentAnswer?.result.matches ?? staleMatches,
            now: now(), calendar: calendar
        )
        .sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
    }

    /// The index's answer, only while it answers the query on screen.
    private var currentAnswer: SearchAnswer? {
        guard let searchAnswer, searchAnswer.query == query else { return nil }
        return searchAnswer
    }

    /// While the answer to the query on screen is pending, the previous
    /// answer's matches for the rows already selected: the open detail (and its
    /// player) must not unload just because one more character was typed. Other
    /// rows wait for the real answer, so an old hit never leaks into a new query.
    private var staleMatches: Set<URL>? {
        guard let searchAnswer, searchAnswer.query != query, !selection.isEmpty else { return nil }
        return searchAnswer.result.matches.intersection(selection)
    }

    /// The index has answered the query on screen (the headless snapshots
    /// turn the run loop until this holds).
    var searchAnswered: Bool { currentAnswer != nil }

    /// Why `entry` matched the search through its transcript or minutes text
    /// (the row's snippet); nil for a summary match, a blank query or an
    /// answer that belongs to an older query.
    func searchHit(for entry: MeetingEntry) -> SearchHit? {
        currentAnswer?.result.hits[entry.dir]
    }

    var canLoadOlder: Bool {
        !MeetingWindow.isSearching(query: query, client: selectedClient, ambito: ambitoFilter, type: typeFilter)
            && MeetingWindow.hasOlder(entries, cutoff: cutoff)
    }

    var clients: [String] { MeetingFilter.clients(in: entries) }

    /// Types present across every session (not just the loaded window), for
    /// the "Tipo" picker.
    var types: [MeetingType] { MeetingFilter.types(in: entries, templates: templates) }

    private var knownTemplateIDs: Set<String> { Set(templates.map(\.id)) }

    /// "N de M reuniones": M = every session on disk.
    var footer: String { Textos.Indice.contador(filtered.count, entries.count) }

    /// The row's memory status, derived from the facts read for this row
    /// plus the config/auth snapshot taken by the last `reload()` — see
    /// `HindsightStatus.derive`.
    func hindsightStatus(for entry: MeetingEntry) -> HindsightStatus? {
        hindsightStatus(from: facts[entry.dir])
    }

    /// The same derivation over facts read elsewhere (the detail's fresh
    /// read of the selected session), with this model's config/auth snapshot.
    func hindsightStatus(from facts: HindsightFacts?) -> HindsightStatus? {
        guard let settingsSnapshot else { return nil }
        return HindsightStatus.derive(
            facts: facts, settings: settingsSnapshot, timeZone: .current, authPaused: authPausedSnapshot
        )
    }

    func loadOlder() {
        extraMonths += 1
        loadMissingFacts()
    }

    /// The window closed: next time it opens on 30 days again.
    func resetWindow() {
        extraMonths = 0
    }

    /// "Ver reunión": show `dir` in the list, selected and scrolled into view.
    /// Clears every filter that could hide it and loads older months until
    /// the window reaches it. A session the loaded list doesn't know yet (first
    /// open, or recorded since the last scan) waits for the next scan
    /// (`reload()` completes it); one still missing after that changes
    /// nothing.
    func focus(on dir: URL) {
        query = ""
        selectedClient = nil
        range = .any
        ambitoFilter = .all
        typeFilter = nil
        pendingFocus = dir
        revealPendingFocus(afterScan: false)
    }

    // MARK: - Full-text search

    /// A keystroke: a blank query forgets the answer and cancels what was
    /// pending; otherwise the index is asked after the quiet delay. The
    /// summary fields already filter the list in the meantime (`filtered`).
    private func scheduleSearch() {
        searchDebouncer.cancel()
        searchTask?.cancel()
        if SearchMatcher.tokens(of: query).isEmpty {
            searchGeneration += 1
            searchAnswer = nil
            return
        }
        if !indexActive { refreshFullText(entries, activating: true) }
        searchDebouncer.request()
    }

    /// Ask the index about the current query over the current entries, after
    /// any refresh still running. The answer is used only if the query and
    /// the generation are still current when it returns.
    @discardableResult
    private func runSearch() -> Task<Void, Never> {
        searchGeneration += 1
        let expected = searchGeneration
        let asked = query
        let entries = self.entries
        let fullText = self.fullText
        let previous = indexTask
        searchTask?.cancel()
        let task = Task {
            await previous?.value
            let result = await fullText.search(query: asked, entries: entries)
            guard !Task.isCancelled, expected == self.searchGeneration, asked == self.query else { return }
            self.searchAnswer = SearchAnswer(query: asked, result: result)
            // Rows only the search brought in (older than the window) have no
            // memory facts yet.
            self.loadMissingFacts()
        }
        searchTask = task
        return task
    }

    /// After a scan published `scanned`: bring the index in line (re-reading
    /// only files whose stamp changed), then refresh an active search.
    private func refreshFullText(_ scanned: [MeetingEntry], activating: Bool = false) {
        // A scan that lands while a query is already typed (the window reopened
        // with its text) builds the index too.
        if activating || !SearchMatcher.tokens(of: query).isEmpty { indexActive = true }
        guard indexActive else { return }
        let fullText = self.fullText
        let previous = indexTask
        // A newer refresh supersedes the one still reading (the actor checks
        // `Task.isCancelled` between sessions).
        previous?.cancel()
        indexTask = Task {
            await previous?.value
            await fullText.refresh(scanned)
            guard self.indexActive, !Task.isCancelled else { return }
            // A keystroke's own search is already scheduled; only a rescan
            // re-runs an active one.
            if !activating, !SearchMatcher.tokens(of: self.query).isEmpty { self.runSearch() }
        }
    }

    /// The window closed: drop the index and any answer (a menu-bar app lives
    /// for weeks; the next `reload()` rebuilds it off the main thread).
    func clearFullText() {
        indexActive = false
        searchDebouncer.cancel()
        searchTask?.cancel()
        searchGeneration += 1
        searchAnswer = nil
        let fullText = self.fullText
        let previous = indexTask
        previous?.cancel()
        indexTask = Task {
            await previous?.value
            await fullText.clear()
        }
    }

    func consumeScrollTarget() {
        scrollTarget = nil
    }

    private func revealPendingFocus(afterScan: Bool) {
        guard let target = pendingFocus else { return }
        let wanted = target.standardizedFileURL.path
        guard let entry = entries.first(where: { $0.dir.standardizedFileURL.path == wanted }) else {
            // Not in the list: a fresh scan is the last chance.
            if afterScan { pendingFocus = nil }
            return
        }
        pendingFocus = nil
        while !filtered.contains(where: { $0.dir == entry.dir }), canLoadOlder { extraMonths += 1 }
        selection = [entry.dir]
        scrollTarget = entry.dir
        loadMissingFacts()
    }

    /// Write `ambito` (nil = "Sin clasificar") to each session's meta.json and
    /// patch the loaded rows in place — no rescan, no memory facts re-read.
    /// A session whose meta.json can't be updated (missing, not a JSON
    /// object) is logged and left as it was; the others still change.
    func classify(_ dirs: [URL], as ambito: Ambito?) {
        var changed = false
        var wrote = false
        for dir in dirs {
            do {
                try SessionFiles.setAmbito(ambito, in: dir)
                wrote = true
            } catch {
                FileHandle.standardError.write(Data("meetings: could not set ambito for \(dir.lastPathComponent): \(error)\n".utf8))
                continue
            }
            if let index = entries.firstIndex(where: { $0.dir == dir }) {
                entries[index].ambito = ambito
                changed = true
            }
        }
        // A scan already in flight read meta.json before these writes and
        // would publish the old ámbito; a newer reload supersedes it.
        if changed, reloading {
            reload()
        }
        // Once for the whole batch, and only if something was written. The
        // sender is this model: its own window skips the message (its rows
        // are already patched), any other window's model reloads.
        if wrote {
            notifications.post(name: .meetingVoxMeetingIndexDidChange, object: self)
        }
    }

    /// Drop sessions that left the recordings folder (moved to the Trash):
    /// their rows, facts and selection go at once, without waiting for a
    /// rescan. A scan already in flight read the folders before the move, so
    /// it is superseded by a newer one.
    func remove(_ dirs: [URL]) {
        let gone = Set(dirs)
        guard !gone.isEmpty else { return }
        entries.removeAll { gone.contains($0.dir) }
        for dir in gone { facts[dir] = nil }
        selection.subtract(gone)
        if reloading { reload() }
    }

    /// Rescan every session (cheap), then read facts for the rows it will
    /// show before publishing both, so a refresh never blanks the memory
    /// lines. A stale scan (superseded by a newer reload) is dropped.
    @discardableResult
    func reload() -> Task<Void, Never> {
        reloadCount += 1
        generation += 1
        let expected = generation
        reloading = true
        let index = self.index
        let root = self.root
        let configNow = config()
        let options = configNow.hindsightEnabled ? HindsightFacts.Options(config: configNow, timeZone: .current) : nil
        // One snapshot for every row this pass, instead of each row parsing
        // config.json (and reading auth/bank state) on its own.
        let settings = HindsightStatus.Settings(config: configNow)
        let authPaused = hindsightAuthPaused()
        let banks = otherBanks()
        let defaultBankNow = defaultBank()
        let templates = listTemplates()
        let task = Task {
            let scanned = await index.scan(root: root)
            guard expected == self.generation else { return }
            // Before `visible(in:)`: the type filter resolves against them.
            self.templates = templates
            var fresh: [URL: HindsightFacts] = [:]
            if let options {
                fresh = await index.facts(for: self.visible(in: scanned).map(\.dir), options: options)
            }
            guard expected == self.generation else { return }
            self.entries = scanned
            self.hasLoaded = true
            self.facts = fresh
            self.settingsSnapshot = settings
            self.authPausedSnapshot = authPaused
            self.otherBanksSnapshot = banks
            self.defaultBankSnapshot = defaultBankNow
            self.reloading = false
            self.refreshFullText(scanned)
            // A type that vanished (minutes deleted or regenerated with
            // another template) would leave the picker on an invalid tag and
            // the list empty: back to every type.
            if let typeFilter = self.typeFilter, !self.types.contains(typeFilter) {
                self.typeFilter = nil
            }
            self.revealPendingFocus(afterScan: true)
        }
        factsTask = task
        return task
    }

    /// Facts for shown rows not read yet (after "Cargar meses anteriores", a
    /// search, a client or a range change). Chained after the previous read
    /// so keystrokes never read the same folder twice; a reload in between
    /// drops the result.
    @discardableResult
    func loadMissingFacts() -> Task<Void, Never> {
        guard let options = factsOptions else { return Task {} }
        let expected = generation
        let index = self.index
        let previous = factsTask
        let task = Task {
            await previous?.value
            guard expected == self.generation else { return }
            let missing = self.filtered.map(\.dir).filter { self.facts[$0] == nil }
            guard !missing.isEmpty else { return }
            let fresh = await index.facts(for: missing, options: options)
            guard expected == self.generation else { return }
            self.facts.merge(fresh) { _, new in new }
        }
        factsTask = task
        return task
    }

    private var factsOptions: HindsightFacts.Options? {
        let config = config()
        return config.hindsightEnabled ? HindsightFacts.Options(config: config, timeZone: .current) : nil
    }
}
