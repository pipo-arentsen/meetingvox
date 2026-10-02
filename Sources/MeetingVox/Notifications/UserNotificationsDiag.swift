import Foundation
import UserNotifications

/// What `diag --mode notifications` reads from the center. **Reading only**:
/// it never requests authorization and never posts. Categories are registered
/// in this process first (as the app does at launch) and read back.
extension UserNotificationsSetup {
    struct ReadBack {
        var authorization: UNAuthorizationStatus
        var alertSetting: UNNotificationSetting
        var categories: [String: [String]]
    }

    /// Blocks up to `timeout` seconds; nil if the center did not answer.
    static func readBack(timeout: TimeInterval = 10) -> ReadBack? {
        final class Box: @unchecked Sendable {
            var settings: UNNotificationSettings?
            var categories: Set<UNNotificationCategory>?
        }
        let box = Box()
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(categories())
        // The center applies the registration asynchronously.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let settingsDone = DispatchSemaphore(value: 0)
        center.getNotificationSettings {
            box.settings = $0
            settingsDone.signal()
        }
        let categoriesDone = DispatchSemaphore(value: 0)
        center.getNotificationCategories {
            box.categories = $0
            categoriesDone.signal()
        }
        let deadline = DispatchTime.now() + timeout
        guard settingsDone.wait(timeout: deadline) == .success,
              categoriesDone.wait(timeout: deadline) == .success,
              let settings = box.settings, let registered = box.categories
        else { return nil }
        return ReadBack(
            authorization: settings.authorizationStatus, alertSetting: settings.alertSetting,
            categories: Dictionary(uniqueKeysWithValues: registered.map { ($0.identifier, $0.actions.map(\.identifier)) })
        )
    }
}
