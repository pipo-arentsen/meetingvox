import Foundation

/// When `EventKitCalendarSource` may keep its (non-Sendable) store, kept
/// generic and pure so tests exercise it with plain values and never build an
/// `EKEventStore`. A store only answers correctly if it was created while
/// access was already granted, so reading drops the store whenever access is
/// not granted and recreates it on the transition to authorized: a grant made
/// later in System Settings works without restarting the app.
struct CalendarStoreCache<Store> {
    private var cached: Store?
    private var wasAuthorized = false

    /// The store for reading events; nil (and nothing kept) unless authorized.
    mutating func forReading(status: CalendarSystemStatus, make: () -> Store) -> Store? {
        guard status == .authorized else {
            cached = nil
            wasAuthorized = false
            return nil
        }
        if !wasAuthorized {
            cached = nil // the one made for the request predates the grant
            wasAuthorized = true
        }
        if let cached { return cached }
        let created = make()
        cached = created
        return created
    }

    /// The store the access request needs while nothing is granted yet.
    mutating func forRequest(make: () -> Store) -> Store {
        if let cached { return cached }
        let created = make()
        cached = created
        return created
    }
}
