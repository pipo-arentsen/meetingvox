import Foundation

@testable import MeetingVox

/// Test builders for the calendar core. Dates are whole seconds from a fixed
/// base so ranges read as minutes.
enum CalendarFixtures {
    /// 2026-09-30 15:00:00 UTC.
    static let base = Date(timeIntervalSince1970: 1_790_780_400)

    static func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    static func snapshot(
        id: String = "e1", title: String = "Weekly", start: Double = 0, end: Double = 60,
        allDay: Bool = false, cancelled: Bool = false, selfStatus: CalendarParticipantStatus? = nil,
        organizer: CalendarParticipant? = nil, attendees: [CalendarParticipant] = [],
        videoURLs: [URL] = []
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: id, externalID: "ext-\(id)", title: title, start: at(start), end: at(end),
            isAllDay: allDay, isCancelled: cancelled, selfStatus: selfStatus,
            organizer: organizer, attendees: attendees, videoURLs: videoURLs)
    }

    static func person(
        _ name: String?, email: String? = nil, isSelf: Bool = false,
        status: CalendarParticipantStatus? = .accepted
    ) -> CalendarParticipant {
        CalendarParticipant(name: name, email: email, isSelf: isSelf, status: status)
    }
}
