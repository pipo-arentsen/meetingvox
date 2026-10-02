import Foundation
import Observation

/// The Tareas page's state (change 5): the search text and the owner filter,
/// over the tasks of every session in `MeetingsModel.entries` — the list's
/// 30-day paging does not apply here. Everything drawn is derived from that
/// one scan by `TaskAggregator`, so a rescan refreshes the page for free.
///
/// Reads no config, Keychain or disk: the entries arrive from the list
/// engine, and the row link goes out through `onOpen`.
@MainActor
@Observable
final class TasksPageModel {
    private let meetings: MeetingsModel

    var query = ""
    var who: TaskWhoFilter = .all

    /// Opens a session on its Resumen tab (`MainWindowModel` wires it to
    /// `focus(on:tab:)`).
    @ObservationIgnored var onOpen: (URL) -> Void = { _ in }

    init(meetings: MeetingsModel) {
        self.meetings = meetings
    }

    /// The rows built for one `MeetingsModel.entriesRevision`: a body reads
    /// `rows` several times (list, counter, empty state, owner options), and
    /// flattening every session's tasks each time would repeat on every keystroke.
    @ObservationIgnored private var cached: (revision: Int, rows: [TaskRow])?
    /// How many times the rows were built (tests).
    @ObservationIgnored private(set) var buildCount = 0

    /// Every task of every session, newest meeting first.
    var rows: [TaskRow] {
        let revision = meetings.entriesRevision  // read first: this is what the view observes
        if let cached, cached.revision == revision { return cached.rows }
        let built = TaskAggregator.build(meetings.entries)
        cached = (revision, built)
        buildCount += 1
        return built
    }

    var visible: [TaskRow] { TaskAggregator.filter(rows, query: query, who: who) }

    var whoOptions: [String] { TaskAggregator.whoOptions(in: rows) }

    /// The picker's people: `whoOptions`, plus the selected one when a rescan
    /// dropped them, so the selection always has a matching tag.
    var whoChoices: [String] {
        var names = whoOptions
        if case .person(let name) = who, !names.contains(name) { names.append(name) }
        return names
    }

    /// Summaries that still lack the tasks key (what "Reconstruir índice" fills).
    var notExtractedCount: Int { TaskAggregator.notExtractedCount(meetings.entries) }

    var isFiltering: Bool {
        who != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var counter: String { Textos.Tareas.contador(visible.count, de: rows.count) }

    var emptyState: TasksEmptyState? {
        TasksEmptyState.of(hasLoaded: meetings.hasLoaded, total: rows.count, shown: visible.count)
    }

    func clearFilters() {
        query = ""
        who = .all
    }

    /// A row's meeting link.
    func open(_ row: TaskRow) { onOpen(row.dir) }
}
