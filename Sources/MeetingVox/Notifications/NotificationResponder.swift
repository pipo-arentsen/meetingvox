import Foundation
import UserNotifications

/// The center's delegate: shows notices while the app is frontmost too, and
/// turns a tap into an `AppAction` for `AppController.perform`.
///
/// Delegate methods arrive off the main thread. The response is reduced to
/// plain strings here (nothing non-`Sendable` crosses to the main actor), the
/// pure router decides, and only the resulting value hops over.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let handler: @Sendable @MainActor (AppAction) -> Void

    init(handler: @escaping @Sendable @MainActor (AppAction) -> Void) {
        self.handler = handler
    }

    /// An accessory app is "frontmost" whenever one of its windows is key;
    /// without this a notice arriving then would be swallowed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let userInfo = content.userInfo.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        guard let action = NotificationActionRouter.route(
            action: response.actionIdentifier, category: content.categoryIdentifier, userInfo: userInfo
        ) else { return }
        await handler(action)
    }
}
