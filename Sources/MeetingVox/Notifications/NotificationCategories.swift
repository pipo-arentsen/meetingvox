import Foundation

/// The categories and buttons of the native notices, and what each `Notice`
/// carries in its `userInfo`. Pure data: the native backend registers
/// `all` with the notification center and the router reads back what a tap
/// carries, so the two never drift apart (a test walks every button through
/// the router).
enum NotificationCategories {
    enum CategoryID {
        static let ready = "mv.ready"
        static let readyMemory = "mv.ready.memory"
        static let minutes = "mv.minutes"
        static let failureRetry = "mv.failure.retry"
        static let failure = "mv.failure"
        static let info = "mv.info"
    }

    enum ActionID {
        static let open = "mv.open"
        static let memory = "mv.memory"
        static let retry = "mv.retry"
        static let view = "mv.view"
    }

    /// `userInfo` keys. Values are always plain strings.
    enum Key {
        /// Absolute path of the session folder.
        static let session = "session"
        /// `Notice.Stage.rawValue`, failures only.
        static let stage = "stage"
        /// A bare `minuta*.md` name, minutes notices only.
        static let file = "file"
    }

    struct Action: Equatable {
        let id: String
        let title: String
        /// Bring the app forward when tapped. Only "Ver reunión" needs it: it
        /// shows a window; the others act in the background.
        let foreground: Bool
    }

    struct Category: Equatable {
        let id: String
        let actions: [Action]
    }

    private static let open = Action(id: ActionID.open, title: Textos.Notificacion.accionAbrir, foreground: false)
    private static let memory = Action(id: ActionID.memory, title: Textos.Notificacion.accionMemoria, foreground: false)
    private static let retry = Action(id: ActionID.retry, title: Textos.Notificacion.accionReintentar, foreground: false)
    private static let view = Action(id: ActionID.view, title: Textos.Notificacion.accionVerReunion, foreground: true)

    static let all: [Category] = [
        Category(id: CategoryID.ready, actions: [open]),
        Category(id: CategoryID.readyMemory, actions: [open, memory]),
        Category(id: CategoryID.minutes, actions: [open]),
        Category(id: CategoryID.failureRetry, actions: [retry, view]),
        Category(id: CategoryID.failure, actions: [view]),
        Category(id: CategoryID.info, actions: []),
    ]

    static func categoryID(for kind: Notice.Kind) -> String {
        switch kind {
        case .ready(let memoryAction): memoryAction ? CategoryID.readyMemory : CategoryID.ready
        case .minutesReady: CategoryID.minutes
        case .failure(_, let retryable): retryable ? CategoryID.failureRetry : CategoryID.failure
        case .info: CategoryID.info
        }
    }

    /// What a tap needs to find its way back: the session, plus the stage of
    /// a failure or the file of a minutes notice. Nothing without a session.
    static func userInfo(for notice: Notice) -> [String: String] {
        guard let session = notice.session else { return [:] }
        var info = [Key.session: session.path]
        switch notice.kind {
        case .failure(let stage, _): info[Key.stage] = stage.rawValue
        case .minutesReady(let file): info[Key.file] = file
        case .ready, .info: break
        }
        return info
    }

    /// What differs between the table above and the categories the center
    /// reports back (id → action ids): empty when they agree. Action order
    /// is not compared.
    static func problems(readBack: [String: [String]]) -> [String] {
        var problems: [String] = []
        for category in all {
            guard let actions = readBack[category.id] else {
                problems.append("missing category \(category.id)")
                continue
            }
            let expected = category.actions.map(\.id)
            if Set(actions) != Set(expected) || actions.count != expected.count {
                problems.append("category \(category.id) has actions [\(actions.joined(separator: ", "))], expected [\(expected.joined(separator: ", "))]")
            }
        }
        let known = Set(all.map(\.id))
        for id in readBack.keys.sorted() where !known.contains(id) {
            problems.append("unexpected category \(id)")
        }
        return problems
    }
}
