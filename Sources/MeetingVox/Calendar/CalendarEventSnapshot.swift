import Foundation

/// What one invitee looks like once it crosses out of EventKit. Our own
/// enum (not `EKParticipantStatus`), so the pure core never imports EventKit.
enum CalendarParticipantStatus: String, Sendable, Equatable, CaseIterable {
    case unknown, pending, accepted, declined, tentative, delegated
}

/// An organizer or invitee. `email` exists only to be matched on this Mac
/// and is stored in meta.json; it never reaches a prompt or Hindsight
/// (`CalendarInvitees.offMac` keeps names only). `status` is nil for the
/// organizer.
struct CalendarParticipant: Sendable, Equatable {
    var name: String?
    var email: String?
    var isSelf: Bool
    var status: CalendarParticipantStatus?
}

/// One calendar event as a plain Sendable value: the only thing the
/// EventKit actor hands out, so no `EK*` type crosses its boundary. Notes
/// are never part of it; `videoURLs` are read for matching only and are not
/// stored (`CalendarEventRecord` has no URL field).
struct CalendarEventSnapshot: Sendable, Equatable {
    var id: String
    var externalID: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var isCancelled: Bool
    /// The current user's own answer, when they are an invitee.
    var selfStatus: CalendarParticipantStatus?
    var organizer: CalendarParticipant?
    var attendees: [CalendarParticipant]
    var videoURLs: [URL]
}
