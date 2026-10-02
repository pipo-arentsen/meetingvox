import Foundation

/// Which sessions "Reconstruir índice" should extract tasks for: those whose
/// `resumen.json` predates the `tasks` field. Pure over `Facts`; the API-key /
/// model / `summary.enabled` / transcript gate (`SummaryGate`) is applied by
/// the coordinator on top.
enum TasksBackfill {
    struct Facts: Sendable, Equatable {
        /// `resumen.json` is a readable JSON object.
        let hasSummary: Bool
        /// Its RAW object has a `tasks` key — the same test the merge refuses
        /// on, not the decoded optional, so a malformed `tasks` (which decodes
        /// as nil) is never extracted over.
        let hasTasksKey: Bool
        let summaryPending: Bool
        let minutesPending: Bool
        let tasksError: Bool

        init(hasSummary: Bool, hasTasksKey: Bool, summaryPending: Bool, minutesPending: Bool, tasksError: Bool) {
            self.hasSummary = hasSummary
            self.hasTasksKey = hasTasksKey
            self.summaryPending = summaryPending
            self.minutesPending = minutesPending
            self.tasksError = tasksError
        }

        init(summaryObject: [String: Any]?, summaryPending: Bool, minutesPending: Bool, tasksError: Bool) {
            self.init(
                hasSummary: summaryObject != nil, hasTasksKey: summaryObject?["tasks"] != nil,
                summaryPending: summaryPending, minutesPending: minutesPending, tasksError: tasksError
            )
        }

        static func read(_ dir: URL) -> Facts {
            let object = (try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return Facts(
                summaryObject: object,
                summaryPending: SessionFiles.exists(SessionFiles.summaryPending, in: dir),
                minutesPending: SessionFiles.exists(SessionFiles.minutesPending, in: dir),
                tasksError: SessionFiles.exists(SessionFiles.tasksError, in: dir)
            )
        }
    }

    /// A readable summary without a `tasks` key, no summary or minutes job in
    /// flight for it, and no earlier backfill failure (`tareas.error` is
    /// skipped like `resumen.error`). A leftover `tareas.pendiente` does not
    /// disqualify: it is a stalled job that a rebuild may re-enqueue.
    static func isCandidate(_ facts: Facts) -> Bool {
        facts.hasSummary && !facts.hasTasksKey
            && !facts.summaryPending && !facts.minutesPending && !facts.tasksError
    }

    enum FailureKind: Equatable {
        /// About this session's own content (the model never produced usable
        /// JSON, or spent its output budget): retrying the same session will
        /// not help, so it is marked `tareas.error`.
        case content
        /// About the key, the model or the account: says nothing about the
        /// session, so its marker stays and the pass stops.
        case environment
        /// The task running the job was cancelled (shutdown, superseded):
        /// says nothing about the session or the account, so its marker
        /// stays and nothing is written.
        case cancelled
    }

    /// Only a failure that would repeat for this session is permanent for it.
    static func classify(_ error: Error) -> FailureKind {
        switch error {
        case is CancellationError:
            .cancelled
        case is SummaryError:
            .content
        case let error as OpenRouterError:
            error == .outputTruncated || error == .emptyContent ? .content : .environment
        case let error as MinutesError:
            switch error {
            case .transcriptUnreadable, .emptyTranscript: .content
            default: .environment
            }
        default:
            // A merge or file problem with this session's own files.
            .content
        }
    }
}
