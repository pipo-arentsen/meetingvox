import Foundation

/// Which sessions the main window draws from: the last 30
/// days, one calendar month further back per "Cargar meses anteriores";
/// while there is search text, a chosen client, ámbito or type, every
/// session. Pure.
enum MeetingWindow {
    static let initialDays = 30

    /// Oldest start date shown: the start of today minus 30 days, minus
    /// `extraMonths` calendar months.
    static func cutoff(extraMonths: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let base = calendar.date(byAdding: .day, value: -initialDays, to: today) ?? today
        return calendar.date(byAdding: .month, value: -extraMonths, to: base) ?? base
    }

    /// Search text, a client, an ámbito or a type: every session is a
    /// candidate (these filters search like the client one).
    static func isSearching(
        query: String, client: String?, ambito: AmbitoFilter = .all, type: MeetingType? = nil
    ) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(client ?? "").isEmpty
            || ambito != .all || type != nil
    }

    /// Sessions without a start date are always in the window: there is
    /// nothing to page them by, and they would otherwise never show.
    static func candidates(
        _ entries: [MeetingEntry], query: String, client: String?,
        ambito: AmbitoFilter = .all, type: MeetingType? = nil, cutoff: Date
    ) -> [MeetingEntry] {
        guard !isSearching(query: query, client: client, ambito: ambito, type: type) else { return entries }
        return entries.filter { ($0.started ?? .distantFuture) >= cutoff }
    }

    static func hasOlder(_ entries: [MeetingEntry], cutoff: Date) -> Bool {
        entries.contains { ($0.started ?? .distantFuture) < cutoff }
    }
}
