import Foundation

/// One block of the main window's meeting list: "Hoy", "Ayer", a weekday, a
/// month, or the undated tail.
struct ListSection: Equatable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case today
        case yesterday
        /// `Calendar` weekday (1 = Sunday): the rest of the last 7 days.
        case weekday(Int)
        case month(year: Int, month: Int)
        case undated
    }

    let kind: Kind
    let entries: [MeetingEntry]

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .today: Textos.Principal.hoy
        case .yesterday: Textos.Principal.ayer
        case .weekday(let weekday): Textos.Principal.diasLargos[weekday - 1]
        case .month(let year, let month): Textos.Principal.mes(month, year)
        case .undated: Textos.Principal.sinFecha
        }
    }
}

/// Builds the list's sections: Hoy, Ayer, weekday names for the
/// rest of the last 7 days, then one section per calendar month; sessions
/// without a start date go last. Newest first everywhere. Pure — the clock
/// and calendar (hence the time zone) are injected.
enum ListSections {
    /// Days back from today that still get a weekday name (2...6; today is 0,
    /// yesterday 1, and 7+ falls to its month).
    private static let weekdayRange = 2...6

    static func build(_ entries: [MeetingEntry], now: Date, calendar: Calendar) -> [ListSection] {
        let today = calendar.startOfDay(for: now)
        let dated = entries.filter { $0.started != nil }.sorted(by: newestFirst)
        let undated = entries.filter { $0.started == nil }.sorted { $0.dir.lastPathComponent > $1.dir.lastPathComponent }

        var sections: [ListSection] = []
        var currentKind: ListSection.Kind?
        var bucket: [MeetingEntry] = []
        func flush() {
            if let currentKind, !bucket.isEmpty { sections.append(ListSection(kind: currentKind, entries: bucket)) }
            bucket = []
        }
        for entry in dated {
            let kind = kind(of: entry.started!, today: today, calendar: calendar)
            if kind != currentKind {
                flush()
                currentKind = kind
            }
            bucket.append(entry)
        }
        flush()
        if !undated.isEmpty { sections.append(ListSection(kind: .undated, entries: undated)) }
        return sections
    }

    private static func newestFirst(_ a: MeetingEntry, _ b: MeetingEntry) -> Bool {
        let (x, y) = (a.started ?? .distantPast, b.started ?? .distantPast)
        if x != y { return x > y }
        return a.dir.lastPathComponent > b.dir.lastPathComponent
    }

    /// A start after today (clock skew) is shown under Hoy rather than
    /// inventing a "future" section.
    private static func kind(of started: Date, today: Date, calendar: Calendar) -> ListSection.Kind {
        let day = calendar.startOfDay(for: started)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch daysAgo {
        case ..<1: return .today
        case 1: return .yesterday
        case let n where weekdayRange.contains(n): return .weekday(calendar.component(.weekday, from: day))
        default:
            let parts = calendar.dateComponents([.year, .month], from: day)
            return .month(year: parts.year ?? 0, month: parts.month ?? 1)
        }
    }
}
