import Foundation

/// Best-effort user-visible notification for callers that only have a title
/// and a body (recorder notices, the glossary result). Everything else
/// builds a `Notice` (`NoticeBuilder`) and posts it through
/// `Notifications.shared`.
func notifyUser(title: String, body: String) {
    Notifications.shared.post(Notice(title: title, body: body))
}
