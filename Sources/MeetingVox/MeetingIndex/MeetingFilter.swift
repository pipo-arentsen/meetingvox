import Foundation

/// Pure filtering for the main window: case- and diacritic-insensitive
/// AND-token search over the summary fields, an exact client filter, the
/// ámbito and type filters, and a date range. `now`/`calendar` are injected
/// so tests (and the window) share one clock.
enum MeetingFilter {
    enum Range: Sendable, Equatable, Hashable, CaseIterable {
        case any
        case last7Days
        case thisMonth
    }

    static func apply(
        _ entries: [MeetingEntry], query: String, client: String?, range: Range,
        ambito: AmbitoFilter = .all, type: MeetingType? = nil, knownTemplateIDs: Set<String> = [],
        fullTextMatches: Set<URL>? = nil,
        now: Date, calendar: Calendar
    ) -> [MeetingEntry] {
        let tokens = normalize(query).split(separator: " ").map(String.init)
        return entries.filter { entry in
            matchesQuery(entry, tokens: tokens, fullTextMatches: fullTextMatches)
                && matchesClient(entry, client: client)
                && ambito.matches(entry.ambito)
                && matchesType(entry, type: type, knownTemplateIDs: knownTemplateIDs)
                && matchesRange(entry, range: range, now: now, calendar: calendar)
        }
    }

    /// Every distinct, non-empty `client` across `entries`, sorted.
    static func clients(in entries: [MeetingEntry]) -> [String] {
        let set = Set(entries.compactMap { $0.summary?.client }.filter { !$0.isEmpty })
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Every type present in `entries`, for the "Tipo" picker: templates by
    /// label, then "Sin plantilla", then "Sin minuta".
    static func types(in entries: [MeetingEntry], templates: [MinutesTemplate]) -> [MeetingType] {
        let known = Set(templates.map(\.id))
        let present = Set(entries.map { MeetingType.of($0, knownTemplateIDs: known) })
        let named = present
            .filter { if case .template = $0 { return true } else { return false } }
            .sorted {
                $0.label(templates: templates).localizedStandardCompare($1.label(templates: templates)) == .orderedAscending
            }
        return named + [MeetingType.unknown, .noMinutes].filter(present.contains)
    }

    private static func matchesType(_ entry: MeetingEntry, type: MeetingType?, knownTemplateIDs: Set<String>) -> Bool {
        guard let type else { return true }
        return MeetingType.of(entry, knownTemplateIDs: knownTemplateIDs) == type
    }

    /// An empty query matches everything. Otherwise the summary fields decide
    /// at once; `fullTextMatches` (the index's answer for this same query,
    /// which also covers tokens split across metadata and transcript/minutes)
    /// adds the sessions only their text matches. nil = the index has not
    /// answered: metadata only.
    private static func matchesQuery(_ entry: MeetingEntry, tokens: [String], fullTextMatches: Set<URL>?) -> Bool {
        guard !tokens.isEmpty else { return true }
        let haystack = normalize(haystackText(entry))
        if tokens.allSatisfy({ haystack.contains($0) }) { return true }
        return fullTextMatches?.contains(entry.dir) ?? false
    }

    /// Title, summary text, client and topics/participants — everything
    /// search covers — plus the linked calendar event's title,
    /// organizer and invitee names (never emails), which count with or without
    /// a summary. An entry with neither is unsearchable text-wise (only the
    /// client/range filters, and an empty query, apply).
    /// Internal: the full-text index folds and matches the same text.
    static func haystackText(_ entry: MeetingEntry) -> String {
        var pieces: [String] = []
        if let summary = entry.summary {
            pieces += [summary.title, summary.summary, summary.client ?? ""] + summary.topics + summary.participants
        }
        if let event = entry.calendarEvent {
            pieces += [event.title] + CalendarInvitees.searchNames(event)
        }
        return pieces.joined(separator: " ")
    }

    /// Case- and diacritic-folded text; the Tareas search folds the same way.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private static func matchesClient(_ entry: MeetingEntry, client: String?) -> Bool {
        guard let client, !client.isEmpty else { return true }
        return entry.summary?.client == client
    }

    private static func matchesRange(_ entry: MeetingEntry, range: Range, now: Date, calendar: Calendar) -> Bool {
        switch range {
        case .any:
            return true
        case .last7Days:
            guard let started = entry.started else { return false }
            let cutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            return started >= cutoff
        case .thisMonth:
            guard let started = entry.started else { return false }
            let nowParts = calendar.dateComponents([.year, .month], from: now)
            let startedParts = calendar.dateComponents([.year, .month], from: started)
            return nowParts.year == startedParts.year && nowParts.month == startedParts.month
        }
    }
}
