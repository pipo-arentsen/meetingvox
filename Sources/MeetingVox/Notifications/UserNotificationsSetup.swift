import Foundation
import UserNotifications

/// Registers the delegate and the categories with the center. Bundled only:
/// callers check `NotifierFactory.currentKind` first.
enum UserNotificationsSetup {
    /// Called from `applicationWillFinishLaunching`: a notice tapped while the
    /// app was closed launches it, and the response is delivered to the
    /// delegate set here.
    @MainActor
    static func install(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories(categories())
    }

    static func categories() -> Set<UNNotificationCategory> {
        Set(NotificationCategories.all.map { category in
            UNNotificationCategory(
                identifier: category.id,
                actions: category.actions.map {
                    UNNotificationAction(identifier: $0.id, title: $0.title, options: $0.foreground ? [.foreground] : [])
                },
                intentIdentifiers: [],
                options: []
            )
        })
    }
}
