import Foundation

/// What the app does when the user taps a notice.
enum AppAction: Equatable, Sendable {
    /// The session in the main window (on the Minuta tab if it has minutes).
    case openSession(URL)
    /// One minutes file of a session: `minuta.md` selects its session on the
    /// Minuta tab, any other file opens outside the app (`OpenTarget`).
    case openFile(URL)
    /// The main window, focused on the session.
    case showSession(URL)
    case retry(Notice.Stage, URL)
    case sendToMemory(URL)
}

/// The pure map from a tapped notification to an `AppAction`. Everything a
/// tap carries comes from outside the process' control (notification
/// `userInfo` survives relaunches and is stored by the system), so nothing is
/// trusted: a missing or odd value means "do nothing", and `validated` then
/// checks the session against the recordings root before anything acts.
enum NotificationActionRouter {
    /// `UNNotificationDefaultActionIdentifier` and
    /// `UNNotificationDismissActionIdentifier`, spelled out so this file needs
    /// no UserNotifications import (a test pins them to the framework's).
    static let defaultAction = "com.apple.UNNotificationDefaultActionIdentifier"
    static let dismissAction = "com.apple.UNNotificationDismissActionIdentifier"

    typealias ActionID = NotificationCategories.ActionID
    typealias CategoryID = NotificationCategories.CategoryID
    typealias Key = NotificationCategories.Key

    static func route(action: String, category: String, userInfo: [String: String]) -> AppAction? {
        guard action != dismissAction,
              let offered = offeredActions(in: category),
              action == defaultAction || offered.contains(action),
              let dir = sessionDirectory(userInfo[Key.session])
        else { return nil }

        // The body click stands for the category's primary action.
        guard let effective = action == defaultAction ? primaryAction(of: category) : action else { return nil }
        switch effective {
        case ActionID.open:
            // A missing or odd `file` is not followed: the session opens instead.
            if category == CategoryID.minutes, let name = userInfo[Key.file], let file = minutesFile(named: name, in: dir) {
                return .openFile(file)
            }
            return .openSession(dir)
        case ActionID.memory:
            return .sendToMemory(dir)
        case ActionID.retry:
            guard let raw = userInfo[Key.stage], let stage = Notice.Stage(rawValue: raw) else { return nil }
            return .retry(stage, dir)
        case ActionID.view:
            return .showSession(dir)
        default:
            return nil
        }
    }

    /// The buttons a category registers (nil for a category we don't know).
    private static func offeredActions(in category: String) -> Set<String>? {
        NotificationCategories.all.first { $0.id == category }.map { Set($0.actions.map(\.id)) }
    }

    /// What tapping the notice itself does: open a ready/minutes notice, view
    /// a failure. `info` has no session to go to.
    private static func primaryAction(of category: String) -> String? {
        switch category {
        case CategoryID.ready, CategoryID.readyMemory, CategoryID.minutes: ActionID.open
        case CategoryID.failureRetry, CategoryID.failure: ActionID.view
        default: nil
        }
    }

    /// An absolute path with no `..` component.
    private static func sessionDirectory(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// A bare `minuta*.md` name (`minuta.md`, `minuta.<id>.md`): no
    /// separators, so it can only name a file inside the session.
    private static func minutesFile(named name: String, in dir: URL) -> URL? {
        guard name.hasPrefix("minuta"), name.hasSuffix(".md"),
              !name.contains("/"), !name.contains("..")
        else { return nil }
        return dir.appendingPathComponent(name)
    }

    // MARK: - Minutes retry

    enum MinutesRetry: Equatable {
        /// `MinutesCoordinator.retry`: the automatic request is still owed.
        case retryAutomatic
        /// The main window on the session.
        case showSession
    }

    /// The notice's reading of the shared `MinutesRequestRoute`. Only a
    /// request the automatic path still owes is retried. A session with a
    /// transcript and nothing owed (`.generate`) is *not* generated again:
    /// from disk a failed "Generar minuta con <plantilla>" looks exactly like
    /// that, and generating would silently use another template. Showing the
    /// session lets the user pick. (The window, whose button is the user's
    /// explicit request, does generate in that state.)
    static func minutesRetry(for route: MinutesRequestRoute) -> MinutesRetry {
        route == .retryAutomatic ? .retryAutomatic : .showSession
    }

    // MARK: - Memory

    enum MemoryRequest: Equatable { case send, retry }

    enum MemoryTap: Equatable {
        case send
        case retryNow
        /// The button no longer applies: show the session instead.
        case show
    }

    /// A memory button can be stale (the notice may be hours old), so a tap
    /// re-checks the live status: a first send only where the menu would offer
    /// "Enviar a memoria"/"Enviar igual" (never over "No enviar a memoria",
    /// never for a session already sent or pending, never with the integration
    /// off), a retry only after a failed send.
    static func memoryTap(_ request: MemoryRequest, status: HindsightStatus?) -> MemoryTap {
        switch (request, status) {
        case (.send, .notSent?), (.send, .short?): .send
        case (.retry, .error?): .retryNow
        default: .show
        }
    }

    // MARK: - Validation

    /// The action only if it names a recorded session of this app: a direct
    /// child of `root` (symlinks resolved, so a link out of the root fails)
    /// holding `meta.json`. An `openFile` whose file is gone falls back to
    /// opening the session. The paths of the returned action are standardized.
    static func validated(_ action: AppAction, root: URL, fileManager: FileManager = .default) -> AppAction? {
        func session(_ url: URL) -> URL? {
            let dir = url.standardizedFileURL
            let resolved = dir.resolvingSymlinksInPath()
            guard resolved.deletingLastPathComponent().path == root.standardizedFileURL.resolvingSymlinksInPath().path,
                  fileManager.fileExists(atPath: resolved.appendingPathComponent(SessionFiles.meta).path)
            else { return nil }
            return dir
        }
        switch action {
        case .openSession(let url): return session(url).map(AppAction.openSession)
        case .showSession(let url): return session(url).map(AppAction.showSession)
        case .sendToMemory(let url): return session(url).map(AppAction.sendToMemory)
        case .retry(let stage, let url): return session(url).map { .retry(stage, $0) }
        case .openFile(let url):
            guard let dir = session(url.deletingLastPathComponent()) else { return nil }
            let file = dir.appendingPathComponent(url.lastPathComponent)
            return fileManager.fileExists(atPath: file.path) ? .openFile(file) : .openSession(dir)
        }
    }
}
