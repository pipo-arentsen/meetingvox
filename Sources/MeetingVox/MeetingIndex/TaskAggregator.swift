import Foundation

/// One line of the Tareas page: a task plus the meeting it came from. Pure
/// value, built from the index scan's entries (no disk).
struct TaskRow: Sendable, Equatable, Identifiable {
    /// Folder + position in the meeting's list: stable across rescans while
    /// the summary does not change.
    let id: String
    let dir: URL
    let meetingTitle: String
    let started: Date?
    let task: MeetingTask

    /// `Jue 24 sep` in `timeZone`; nil for an undated meeting.
    func dayText(timeZone: TimeZone) -> String? {
        guard let started else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .day, .month], from: started)
        guard let weekday = parts.weekday, let day = parts.day, let month = parts.month else { return nil }
        return "\(Textos.Indice.diasCortos[weekday - 1]) \(day) \(Textos.Indice.mesesCortos[month - 1])"
    }
}

/// Why the Tareas page has no rows to draw, if it doesn't. Pure.
enum TasksEmptyState: Equatable, Sendable {
    /// The first scan has not published yet.
    case loading
    /// No session has any task (none extracted, or every meeting had none).
    case noTasks
    /// There are tasks but the search or the owner filter hides every one.
    case noMatches

    /// - Returns: nil when there are rows to draw.
    static func of(hasLoaded: Bool, total: Int, shown: Int) -> TasksEmptyState? {
        if shown > 0 { return nil }
        if total > 0 { return .noMatches }
        return hasLoaded ? .noTasks : .loading
    }
}

/// Which owner the Tareas page shows. `person` matches case- and
/// diacritic-insensitively, so "yo" and "Yo" are one person.
enum TaskWhoFilter: Sendable, Equatable, Hashable {
    case all
    case person(String)
    /// Tasks whose owner the model could not name.
    case unassigned
}

/// Pure logic behind the Tareas page: every session's tasks in one
/// flat list, newest meeting first, unknown owners included, with a search
/// and an owner filter.
enum TaskAggregator {
    /// Newest meeting first (undated last); inside a meeting the model's
    /// order is kept. Only summaries that carry tasks contribute.
    static func build(_ entries: [MeetingEntry]) -> [TaskRow] {
        let ordered = entries.enumerated().sorted { a, b in
            switch (a.element.started, b.element.started) {
            case let (x?, y?): x != y ? x > y : a.offset < b.offset
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.offset < b.offset
            }
        }
        return ordered.flatMap { _, entry -> [TaskRow] in
            guard let summary = entry.summary, let tasks = summary.tasks else { return [] }
            let shown = SessionTitle.resolve(
                calendar: entry.calendarEvent?.title, summary: summary.title, header: nil,
                folder: entry.dir.lastPathComponent) ?? entry.dir.lastPathComponent
            return tasks.enumerated().map { index, task in
                TaskRow(
                    id: "\(entry.dir.path)#\(index)", dir: entry.dir, meetingTitle: shown,
                    started: entry.started, task: task
                )
            }
        }
    }

    /// The owners for the picker: distinct (case-insensitively, first
    /// spelling wins), sorted, without the unknown one.
    static func whoOptions(in rows: [TaskRow]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for row in rows {
            guard let name = owner(of: row) else { continue }
            if seen.insert(MeetingFilter.normalize(name)).inserted { names.append(name) }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// AND-token search over what, who, when and the meeting title, then the
    /// owner filter.
    static func filter(_ rows: [TaskRow], query: String, who: TaskWhoFilter) -> [TaskRow] {
        let tokens = MeetingFilter.normalize(query).split(separator: " ").map(String.init)
        return rows.filter { row in
            matches(row, who: who) && matches(row, tokens: tokens)
        }
    }

    /// Meetings "Reconstruir índice" would still extract tasks for (for the
    /// page's note): exactly `TasksBackfill.isCandidate`, so a session with
    /// `tareas.error`, a pending summary or minutes, or a malformed `tasks`
    /// is not promised an extraction.
    static func notExtractedCount(_ entries: [MeetingEntry]) -> Int {
        entries.filter { TasksBackfill.isCandidate($0.tasksBackfillFacts) }.count
    }

    // MARK: - Private

    private static func owner(of row: TaskRow) -> String? {
        guard let who = row.task.who?.trimmingCharacters(in: .whitespacesAndNewlines), !who.isEmpty else { return nil }
        return who
    }

    private static func matches(_ row: TaskRow, who: TaskWhoFilter) -> Bool {
        switch who {
        case .all: true
        case .unassigned: owner(of: row) == nil
        case .person(let name):
            owner(of: row).map { MeetingFilter.normalize($0) == MeetingFilter.normalize(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                ?? false
        }
    }

    private static func matches(_ row: TaskRow, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let text = [row.task.what, row.task.who ?? "", row.task.when ?? "", row.meetingTitle].joined(separator: " ")
        let haystack = MeetingFilter.normalize(text)
        return tokens.allSatisfy { haystack.contains($0) }
    }
}
