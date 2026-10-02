@preconcurrency import EventKit
import Foundation

/// The only file that touches EventKit. An `actor` owns the `EKEventStore`
/// (not Sendable): the predicate, the query and the `EKEvent` ->
/// `CalendarEventSnapshot` mapping all run inside it, so no EK type crosses
/// its boundary. Read-only by construction (no save/remove call), and an
/// event's free-text field is never read. Tests never build this type
/// (`SnapshotHomeGuardTests` enforces the isolation); the store itself is
/// created lazily on the first request or query, so even `status()` is
/// class-level and touches no store. The store is dropped whenever access is
/// not granted and recreated on the transition to authorized
/// (`CalendarStoreCache`), so a grant made later in System Settings works
/// without a restart.
actor EventKitCalendarSource: CalendarSource {
    private var cache = CalendarStoreCache<EKEventStore>()
    private var requestTask: Task<CalendarSystemStatus, Never>?

    init() {}

    /// Class-level and prompt-free: touches no store. Read by `doctor` and
    /// `diag --mode permissions`, which only ever call it from the bundled app.
    static func currentStatus() -> CalendarSystemStatus {
        CalendarStatusMapping.system(rawValue: EKEventStore.authorizationStatus(for: .event).rawValue)
    }

    func status() async -> CalendarSystemStatus { Self.currentStatus() }

    func requestFullAccess() async -> CalendarSystemStatus {
        if let requestTask { return await requestTask.value } // single flight
        // Never a second prompt: the system only asks while undetermined.
        guard Self.currentStatus() == .notDetermined else { return Self.currentStatus() }
        let task = Task { await self.performRequest() }
        requestTask = task
        let result = await task.value
        requestTask = nil
        return result
    }

    private func performRequest() async -> CalendarSystemStatus {
        let store = cache.forRequest { EKEventStore() }
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
        }
        // A store created before the grant keeps answering with no events.
        store.reset()
        return Self.currentStatus()
    }

    func events(overlapping interval: DateInterval) async throws -> [CalendarEventSnapshot] {
        guard let store = cache.forReading(status: Self.currentStatus(), make: { EKEventStore() }) else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).compactMap(Self.snapshot)
    }

    // MARK: - Mapping (runs inside the actor)

    private static func snapshot(_ event: EKEvent) -> CalendarEventSnapshot? {
        guard let id = event.eventIdentifier, let start = event.startDate, let end = event.endDate else { return nil }
        let attendees = event.attendees ?? []
        var organizer = event.organizer.map(participant)
        organizer?.status = nil
        return CalendarEventSnapshot(
            id: id, externalID: event.calendarItemExternalIdentifier ?? "", title: event.title ?? "",
            start: start, end: end, isAllDay: event.isAllDay, isCancelled: event.status == .canceled,
            selfStatus: attendees.first(where: \.isCurrentUser).map { status(of: $0) },
            organizer: organizer, attendees: attendees.map(participant),
            videoURLs: CalendarVideoLink.extract(from: [event.url?.absoluteString, event.location]))
    }

    private static func status(of participant: EKParticipant) -> CalendarParticipantStatus {
        CalendarParticipantStatus(ekRawValue: participant.participantStatus.rawValue)
    }

    private static func participant(_ participant: EKParticipant) -> CalendarParticipant {
        CalendarParticipant(
            name: participant.name, email: CalendarStatusMapping.email(fromParticipantURL: participant.url),
            isSelf: participant.isCurrentUser, status: status(of: participant))
    }
}
