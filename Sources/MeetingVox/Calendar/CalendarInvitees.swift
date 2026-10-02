import Foundation

/// The attendee names that may leave the Mac (prompts, Hindsight
/// `asistentes`): names only, never emails, never the user.
enum CalendarInvitees {
    /// A cap keeps a company-wide invite from flooding a prompt.
    static let cap = 25

    /// Organizer first, then the attendees in event order. Dropped: the user,
    /// nameless entries and names that are (or contain) an address, i.e. an
    /// "@". Duplicates merge ignoring case and padding.
    static func offMac(_ record: CalendarEventRecord) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for name in shareableNames(record) where seen.insert(name.lowercased()).inserted {
            names.append(name)
            if names.count == cap { break }
        }
        return names
    }

    /// Everything search may match besides the title: organizer and invitee
    /// names (the user excluded, nameless and address-like names dropped),
    /// with no cap, since a long invite list should stay findable. Emails are
    /// never searchable.
    static func searchNames(_ record: CalendarEventRecord) -> [String] {
        shareableNames(record)
    }

    /// The one per-person rule: organizer first, then attendees; never the
    /// user, never a blank name, never one that is (or holds) an address.
    private static func shareableNames(_ record: CalendarEventRecord) -> [String] {
        ([record.organizer].compactMap { $0 } + record.attendees).compactMap { person in
            guard !person.isSelf else { return nil }
            let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty || name.contains("@") ? nil : name
        }
    }
}
