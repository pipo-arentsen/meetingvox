import Foundation

/// The one place a real source is chosen. Only the app's bootstrap calls it
/// (with `NotifierFactory.currentKind == .userNotifications`, i.e. the
/// bundled app); `SnapshotHomeGuardTests` keeps it out of tests and of the
/// snapshot harness.
enum CalendarSources {
    static func make(isBundled: Bool) -> any CalendarSource {
        isBundled ? EventKitCalendarSource() : UnavailableCalendarSource()
    }
}
