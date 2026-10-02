import Foundation
import UserNotifications

/// The bundled app's backend: `UNUserNotificationCenter`, with buttons.
/// **Only ever constructed and used when running from the .app** — an
/// unbundled process crashes on `UNUserNotificationCenter.current()`, which
/// is why nothing here touches the center before `post`, and `post` is only
/// reachable through `NotifierFactory` for a bundled process.
///
/// Authorization is requested lazily, on the first post while
/// `.notDetermined` (the moment the user first has something to be told, not
/// at launch). Denied means nothing is shown — no osascript fallback, the
/// user's choice stands — and the ready notice stays claimed (at-most-once).
final class UserNotificationsNotifier: Notifier, @unchecked Sendable {
    private let delivery = Delivery()

    /// What the permission prompt asks for. Shared with the onboarding
    /// "Permitir" so both raise the same prompt.
    static let authorizationOptions: UNAuthorizationOptions = [.alert]

    /// Fire-and-forget: the caller never waits for the permission prompt.
    func post(_ notice: Notice) {
        Task { await delivery.deliver(notice) }
    }

    /// The content of `notice`: the pure category and `userInfo` pieces
    /// attached, and the session folder as thread so one meeting's notices
    /// group together.
    static func content(for notice: Notice) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.categoryIdentifier = NotificationCategories.categoryID(for: notice.kind)
        content.userInfo = NotificationCategories.userInfo(for: notice)
        if let folder = notice.session?.lastPathComponent { content.threadIdentifier = folder }
        return content
    }

    /// Same identifier as the notice: a repost replaces the earlier one.
    static func request(for notice: Notice) -> UNNotificationRequest {
        UNNotificationRequest(identifier: notice.identifier, content: content(for: notice), trigger: nil)
    }

    /// Serializes posts so two notices arriving before the answer to the
    /// permission prompt share one request instead of asking twice.
    private actor Delivery {
        private var inflightAuthorization: Task<NotificationAuthorizationPolicy.Outcome, Never>?
        private var dropLog = NotificationAuthorizationPolicy.DropLog()
        /// A request that threw is not retried for every later notice.
        private var requestFailed = false

        func deliver(_ notice: Notice) async {
            let outcome = await authorization()
            if let line = dropLog.line(for: outcome) { NotificationLog.write(line) }
            guard outcome == .granted else { return }
            do {
                try await UNUserNotificationCenter.current().add(UserNotificationsNotifier.request(for: notice))
            } catch {
                NotificationLog.write("could not post \"\(notice.title)\": \(error)")
            }
        }

        private func authorization() async -> NotificationAuthorizationPolicy.Outcome {
            if let inflightAuthorization { return await inflightAuthorization.value }
            let failedBefore = requestFailed
            let task = Task { await Self.check(requestFailed: failedBefore) }
            inflightAuthorization = task
            let result = await task.value
            inflightAuthorization = nil
            if case .failed = result { requestFailed = true }
            return result
        }

        private static func check(requestFailed: Bool) async -> NotificationAuthorizationPolicy.Outcome {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            switch NotificationAuthorizationPolicy.decide(status, requestFailed: requestFailed) {
            case .post: return .granted
            case .drop: return requestFailed && status == .notDetermined ? .failed("an earlier request failed") : .denied
            case .requestThenPost:
                do {
                    return try await center.requestAuthorization(options: UserNotificationsNotifier.authorizationOptions) ? .granted : .denied
                } catch {
                    return .failed("\(error)")
                }
            }
        }
    }
}
