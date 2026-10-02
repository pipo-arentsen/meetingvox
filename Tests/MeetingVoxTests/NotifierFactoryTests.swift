import Foundation
import Testing
import UserNotifications
@testable import MeetingVox

/// A bare binary, tests and diag use osascript and never touch
/// `UNUserNotificationCenter`; only the bundled .app uses the native backend.
@Suite struct NotifierFactoryTests {
    @Test func aBareBinaryUsesOsaScript() {
        #expect(NotifierFactory.kind(isBundled: false) == .osascript)
    }

    @Test func theBundledAppUsesTheNativeBackend() {
        #expect(NotifierFactory.kind(isBundled: true) == .userNotifications)
    }

    @Test func theKindFollowsTheBundleURLTheProcessRunsFrom() {
        for (path, expected) in [
            ("/Applications/MeetingVox.app", NotifierFactory.Kind.userNotifications),
            ("/Users/x/quill/.build/app/MeetingVox.app", .userNotifications),
            ("/usr/local/bin", .osascript),
            ("/Users/x/quill/.build/release", .osascript),
        ] {
            let bundled = LogRedirect.isBundled(bundleURL: URL(fileURLWithPath: path))
            #expect(NotifierFactory.kind(isBundled: bundled) == expected, "\(path)")
        }
    }

    @Test func theTestProcessIsNotBundledAndSoUsesOsaScript() {
        let bundled = LogRedirect.isBundled(bundleURL: Bundle.main.bundleURL)
        #expect(!bundled)
        #expect(NotifierFactory.kind(isBundled: bundled) == .osascript)
        #expect(Notifications.shared is OsaScriptNotifier)
    }

    @Test func theNativeBackendNeedsABundleIdentifierToo() {
        let app = URL(fileURLWithPath: "/Applications/MeetingVox.app")
        let bare = URL(fileURLWithPath: "/usr/local/bin")
        #expect(NotifierFactory.kind(bundleURL: app, bundleIdentifier: "com.pipostudio.meetingvox") == .userNotifications)
        #expect(NotifierFactory.kind(bundleURL: app, bundleIdentifier: nil) == .osascript)
        #expect(NotifierFactory.kind(bundleURL: app, bundleIdentifier: "") == .osascript)
        #expect(NotifierFactory.kind(bundleURL: bare, bundleIdentifier: "com.apple.dt.xctest.tool") == .osascript)
        #expect(NotifierFactory.kind(bundleURL: bare, bundleIdentifier: nil) == .osascript)
    }

    @Test func theBackendNameIsWhatDiagReports() {
        #expect(NotifierFactory.Kind.osascript.description == "osascript")
        #expect(NotifierFactory.Kind.userNotifications.description == "UserNotifications")
    }

    @Test func theScriptQuotesTitleAndBody() {
        let notice = Notice(title: "MeetingVox — reunión lista", body: "Kickoff — transcripción")
        #expect(OsaScriptNotifier.script(for: notice)
            == #"display notification "Kickoff — transcripción" with title "MeetingVox — reunión lista""#)
    }

    @Test func theScriptEscapesBackslashesAndQuotes() {
        let notice = Notice(title: #"a "b""#, body: #"c\d"#)
        #expect(OsaScriptNotifier.script(for: notice) == #"display notification "c\\d" with title "a \"b\"""#)
    }

    @Test func aSpawnFailureIsLoggedNotSwallowed() {
        final class Logged: @unchecked Sendable {
            private let lock = NSLock()
            private var _lines: [String] = []
            func add(_ l: String) { lock.withLock { _lines.append(l) } }
            var lines: [String] { lock.withLock { _lines } }
        }
        let logged = Logged()
        let notifier = OsaScriptNotifier(executable: "/nonexistent/osascript", log: { logged.add($0) })

        notifier.post(Notice(title: "T", body: "B"))

        #expect(logged.lines.count == 1)
        #expect(logged.lines[0].contains("/nonexistent/osascript"))
    }
}

/// What to do with the current authorization state. Pure over the
/// status enum; the center itself is never read here.
@Suite struct NotificationAuthorizationPolicyTests {
    @Test func notDeterminedAsksOnceThenPosts() {
        #expect(NotificationAuthorizationPolicy.decide(.notDetermined) == .requestThenPost)
    }

    @Test func grantedStatesPost() {
        for status in [UNAuthorizationStatus.authorized, .provisional] {
            #expect(NotificationAuthorizationPolicy.decide(status) == .post, "\(status.rawValue)")
        }
    }

    @Test func deniedDropsWithoutAsking() {
        #expect(NotificationAuthorizationPolicy.decide(.denied) == .drop)
    }

    @Test func aRequestThatFailedIsNotAskedAgainThisRun() {
        #expect(NotificationAuthorizationPolicy.decide(.notDetermined, requestFailed: true) == .drop)
        // ...while a state that already allows posting is unaffected.
        #expect(NotificationAuthorizationPolicy.decide(.authorized, requestFailed: true) == .post)
    }

    @Test func aDeniedNoticeIsLoggedOnlyOnce() {
        var log = NotificationAuthorizationPolicy.DropLog()
        let first = log.line(for: .denied)
        let second = log.line(for: .denied)
        #expect(first?.contains("not allowed") == true)
        #expect(second == nil)
    }

    @Test func aFailedRequestLogsTheRealErrorOnceWithoutTheNotAllowedWording() {
        var log = NotificationAuthorizationPolicy.DropLog()
        let first = log.line(for: .failed("UNErrorDomain error 1"))
        let second = log.line(for: .failed("UNErrorDomain error 1"))
        #expect(first?.contains("UNErrorDomain error 1") == true)
        #expect(first?.contains("not allowed") == false)
        #expect(second == nil)
    }

    @Test func aGrantedOutcomeLogsNothing() {
        var log = NotificationAuthorizationPolicy.DropLog()
        #expect(log.line(for: .granted) == nil)
    }

    @Test func deniedAndFailedAreEachReportedOnce() {
        var log = NotificationAuthorizationPolicy.DropLog()
        let denied = log.line(for: .denied)
        let failed = log.line(for: .failed("boom"))
        #expect(denied != nil)
        #expect(failed != nil)
    }
}

/// The native content carries the pure pieces unchanged.
@Suite struct UserNotificationContentTests {
    private let session = URL(fileURLWithPath: "/Users/x/Recordings/2026.09.29-1000")

    @Test func aFailureNoticeBecomesContentWithCategoryThreadAndUserInfo() {
        let notice = NoticeBuilder.failed(.minutes, session: session)
        let content = UserNotificationsNotifier.content(for: notice)
        #expect(content.title == notice.title)
        #expect(content.body == notice.body)
        #expect(content.categoryIdentifier == "mv.failure.retry")
        #expect(content.threadIdentifier == "2026.09.29-1000")
        #expect(content.userInfo as? [String: String] == ["session": session.path, "stage": "minutes"])
    }

    @Test func aNoticeWithoutASessionHasNoThread() {
        let content = UserNotificationsNotifier.content(for: Notice(title: "T", body: "B"))
        #expect(content.categoryIdentifier == "mv.info")
        #expect(content.threadIdentifier.isEmpty)
        #expect((content.userInfo as? [String: String])?.isEmpty == true)
    }

    @Test func aReadyNoticeWithAMemoryActionUsesTheMemoryCategory() {
        let notice = NoticeBuilder.ready(session: session, label: "Kickoff", parts: [.transcript], memoryAction: true)
        #expect(UserNotificationsNotifier.content(for: notice).categoryIdentifier == "mv.ready.memory")
    }

    @Test func theRequestIdentifierIsTheNoticeIdentifierSoARepostReplaces() {
        let notice = NoticeBuilder.failed(.summary, session: session)
        #expect(UserNotificationsNotifier.request(for: notice).identifier == notice.identifier)
    }
}

/// One place for the "notifications:" stderr prefix.
@Suite struct NotificationLogTests {
    @Test func everyLineCarriesThePrefixAndANewline() {
        #expect(NotificationLog.formatted("could not post") == "notifications: could not post\n")
    }
}
