import Foundation

/// What the Resumen tab shows (DT-1). Pure.
enum ResumenTabState: Equatable, Sendable {
    case summary(MeetingSummary)
    /// `resumen.pendiente`, or a summary job running or waiting to retry.
    case generating
    /// `resumen.error`: the stepper carries "Reintentar".
    case failed
    /// Nothing yet. `applies`: summaries are enabled and can run, so one is
    /// expected; false = they are off (or lack a key/model).
    case none(applies: Bool)

    static func derive(entry: MeetingEntry, live: LiveStages, summaryApplies: Bool) -> ResumenTabState {
        if let summary = entry.summary { return .summary(summary) }
        if entry.summaryState == .pending || live[.summary] != nil { return .generating }
        if entry.summaryState == .failed { return .failed }
        return .none(applies: summaryApplies)
    }
}

/// What the Resumen tab's tasks column shows ("not extracted" is not
/// "none"). Pure.
enum TasksColumnState: Equatable, Sendable {
    /// No `tasks` key: a summary from before task extraction. "Reconstruir
    /// índice" fills it in.
    case notExtracted
    /// Extracted, and the meeting had none.
    case none
    case list([MeetingTask])

    static func of(_ summary: MeetingSummary) -> TasksColumnState {
        guard let tasks = summary.tasks else { return .notExtracted }
        return tasks.isEmpty ? .none : .list(tasks)
    }
}
