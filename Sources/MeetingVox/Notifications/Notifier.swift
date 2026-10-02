import Foundation

/// How a `Notice` reaches the user. Fire-and-forget: a post that fails or is
/// denied is dropped, never retried (the ready notice is claimed at most once).
protocol Notifier: Sendable {
    func post(_ notice: Notice)
}

/// Bare binary, tests and `diag`: `osascript` needs no bundle or entitlement,
/// and shows no actions.
struct OsaScriptNotifier: Notifier {
    var executable = "/usr/bin/osascript"
    /// Where a spawn failure goes (stderr by default): a notice that never
    /// appears should leave a trace.
    var log: @Sendable (String) -> Void = { NotificationLog.write($0) }

    func post(_ notice: Notice) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["-e", Self.script(for: notice)]
        do {
            try task.run()
        } catch {
            log("could not run \(executable): \(error)")
        }
    }

    /// Fixed argv, quoted script: the notice text is only ever a string literal.
    static func script(for notice: Notice) -> String {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "display notification \(quoted(notice.body)) with title \(quoted(notice.title))"
    }
}

/// Picks the backend for this process: the native `UNUserNotificationCenter`
/// only when running from the bundled .app (an unbundled process crashes the
/// moment it touches the center); the bare binary, tests, `doctor` and
/// `diag` post through osascript and never load the center.
enum NotifierFactory {
    enum Kind: Equatable, CustomStringConvertible {
        case osascript
        case userNotifications

        var description: String {
            switch self {
            case .osascript: "osascript"
            case .userNotifications: "UserNotifications"
            }
        }
    }

    static func kind(isBundled: Bool) -> Kind {
        isBundled ? .userNotifications : .osascript
    }

    /// The native center also needs a bundle identifier: a `.app` path
    /// without one (a broken or hand-assembled bundle) would crash it the
    /// same way an unbundled process does.
    static func kind(bundleURL: URL, bundleIdentifier: String?) -> Kind {
        kind(isBundled: LogRedirect.isBundled(bundleURL: bundleURL) && !(bundleIdentifier ?? "").isEmpty)
    }

    /// This process' kind.
    static var currentKind: Kind {
        kind(bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func make(_ kind: Kind) -> any Notifier {
        switch kind {
        case .osascript: OsaScriptNotifier()
        case .userNotifications: UserNotificationsNotifier()
        }
    }
}

enum Notifications {
    /// The process-wide notifier, chosen once from the bundle.
    static let shared: any Notifier = NotifierFactory.make(NotifierFactory.currentKind)
}
