import Foundation

/// The `calendar_event` key of meta.json (additive, optional; absent or JSON
/// null = no link). Holds what a title, a search and a prompt need, and nothing that
/// should not persist: no notes, no URL, no location. Dates are whole
/// seconds, so an ISO 8601 encode/decode round trip compares equal.
struct CalendarEventRecord: Sendable, Equatable {
    let id: String
    let externalID: String
    let title: String
    let start: Date
    let end: Date
    let organizer: CalendarParticipant?
    let attendees: [CalendarParticipant]
    let matchedAt: Date

    init(
        id: String, externalID: String, title: String, start: Date, end: Date,
        organizer: CalendarParticipant?, attendees: [CalendarParticipant], matchedAt: Date
    ) {
        self.id = id
        self.externalID = externalID
        self.title = CalendarText.title(title)
        self.start = Self.wholeSeconds(start)
        self.end = Self.wholeSeconds(end)
        self.organizer = organizer.map(Self.cleaned)
        self.attendees = attendees.map(Self.cleaned)
        self.matchedAt = Self.wholeSeconds(matchedAt)
    }

    init(snapshot: CalendarEventSnapshot, matchedAt: Date) {
        var organizer = snapshot.organizer
        organizer?.status = nil // the organizer's answer is not part of the record
        self.init(
            id: snapshot.id, externalID: snapshot.externalID, title: snapshot.title, start: snapshot.start,
            end: snapshot.end, organizer: organizer, attendees: snapshot.attendees, matchedAt: matchedAt)
    }

    /// Names come from invitations too: one clean line, blank = no name.
    private static func cleaned(_ person: CalendarParticipant) -> CalendarParticipant {
        var person = person
        if let name = person.name.map(CalendarText.name), !name.isEmpty { person.name = name } else { person.name = nil }
        return person
    }

    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    // MARK: - JSON (meta.json values)

    private static func format(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle()) }

    private static func parse(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return (try? Date(text, strategy: Date.ISO8601FormatStyle()))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    /// The value stored under `calendar_event`.
    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "id": id, "external_id": externalID, "title": title,
            "start": Self.format(start), "end": Self.format(end), "matched_at": Self.format(matchedAt),
            "attendees": attendees.map { Self.json($0, withStatus: true) },
        ]
        if let organizer { object["organizer"] = Self.json(organizer, withStatus: false) }
        return object
    }

    private static func json(_ person: CalendarParticipant, withStatus: Bool) -> [String: Any] {
        var object: [String: Any] = ["is_self": person.isSelf]
        if let name = person.name { object["name"] = name }
        if let email = person.email { object["email"] = email }
        if withStatus, let status = person.status { object["status"] = status.rawValue }
        return object
    }

    private static func participant(_ value: Any?, withStatus: Bool) -> CalendarParticipant? {
        guard let object = value as? [String: Any] else { return nil }
        if let flag = object["is_self"], !(flag is Bool) { return nil }
        let status = withStatus ? (object["status"] as? String).flatMap(CalendarParticipantStatus.init(rawValue:)) : nil
        return CalendarParticipant(
            name: object["name"] as? String, email: object["email"] as? String,
            isSelf: object["is_self"] as? Bool ?? false, status: status)
    }

    /// Tolerant read of a meta.json value: nil unless it is an object with a
    /// non-blank `title` and a parseable `start`. A bad `end` falls back to
    /// the start, a bad `matched_at` to the start, a malformed organizer or
    /// attendee entry is dropped; unknown keys are ignored.
    init?(jsonObject value: Any?) {
        guard let object = value as? [String: Any],
            let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
            let start = Self.parse(object["start"])
        else { return nil }
        self.init(
            id: object["id"] as? String ?? "", externalID: object["external_id"] as? String ?? "",
            title: title, start: start, end: Self.parse(object["end"]) ?? start,
            organizer: Self.participant(object["organizer"], withStatus: false),
            attendees: (object["attendees"] as? [Any] ?? []).compactMap { Self.participant($0, withStatus: true) },
            matchedAt: Self.parse(object["matched_at"]) ?? start)
    }
}
