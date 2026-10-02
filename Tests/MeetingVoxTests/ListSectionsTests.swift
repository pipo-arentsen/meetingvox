import Foundation
import Testing
@testable import MeetingVox

@Suite struct ListSectionsTests {
    /// Tuesday 2026-09-29 11:00 in a fixed UTC-3 zone (no DST surprises).
    private let zone = TimeZone(secondsFromGMT: -3 * 3600)!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }
    private var now: Date { at(2026, 9, 29, 11, 0) }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func entry(_ name: String, _ started: Date?) -> MeetingEntry {
        MeetingEntry(
            dir: URL(fileURLWithPath: "/fake/\(name)"), started: started, durationSeconds: nil, app: nil,
            summary: nil, hasMinutes: false, hasTranscript: true
        )
    }

    @Test func specScenarioHoyAyerWeekdayMonthNewestFirst() {
        // Deliberately shuffled: the builder sorts.
        let entries = [
            entry("old", at(2026, 8, 20, 10, 0)),
            entry("today", at(2026, 9, 29, 9, 0)),
            entry("three", at(2026, 9, 26, 10, 0)),
            entry("yesterday", at(2026, 9, 28, 22, 0)),
        ]

        let sections = ListSections.build(entries, now: now, calendar: calendar)

        #expect(sections.map(\.title) == ["Hoy", "Ayer", "Sábado", "Agosto 2026"])
        #expect(sections.map { $0.entries.map(\.dir.lastPathComponent) } == [["today"], ["yesterday"], ["three"], ["old"]])
    }

    @Test func sameSectionIsNewestFirstAndKeepsAllEntries() {
        let entries = [
            entry("a", at(2026, 9, 29, 8, 0)),
            entry("c", at(2026, 9, 29, 10, 30)),
            entry("b", at(2026, 9, 29, 9, 0)),
        ]

        let sections = ListSections.build(entries, now: now, calendar: calendar)

        #expect(sections.count == 1)
        #expect(sections[0].title == "Hoy")
        #expect(sections[0].entries.map(\.dir.lastPathComponent) == ["c", "b", "a"])
    }

    @Test func midnightBoundaryBelongsToTheNewDay() {
        let entries = [
            entry("justAfterMidnight", at(2026, 9, 29, 0, 0)),
            entry("justBefore", at(2026, 9, 28, 23, 59)),
        ]

        let sections = ListSections.build(entries, now: now, calendar: calendar)

        #expect(sections.map(\.title) == ["Hoy", "Ayer"])
    }

    @Test func weekdayCoversTwoToSixDaysAgoAndSevenFallsToMonth() {
        let entries = [
            entry("d2", at(2026, 9, 27, 12, 0)),  // Sunday
            entry("d6", at(2026, 9, 23, 12, 0)),  // Wednesday
            entry("d7", at(2026, 9, 22, 12, 0)),  // exactly 7 days ago
        ]

        let sections = ListSections.build(entries, now: now, calendar: calendar)

        #expect(sections.map(\.title) == ["Domingo", "Miércoles", "Septiembre 2026"])
    }

    @Test func monthsAreSeparatedAcrossYearsNewestFirst() {
        let entries = [
            entry("dec", at(2025, 12, 31, 12, 0)),
            entry("jan", at(2026, 1, 2, 12, 0)),
            entry("jan2", at(2026, 1, 20, 12, 0)),
        ]

        let sections = ListSections.build(entries, now: now, calendar: calendar)

        #expect(sections.map(\.title) == ["Enero 2026", "Diciembre 2025"])
        #expect(sections[0].entries.map(\.dir.lastPathComponent) == ["jan2", "jan"])
    }

    @Test func undatedEntriesGoLastInTheirOwnSection() {
        let entries = [
            entry("nodate", nil),
            entry("today", at(2026, 9, 29, 9, 0)),
            entry("old", at(2026, 3, 1, 9, 0)),
        ]

        let sections = ListSections.build(entries, now: now, calendar: calendar)

        #expect(sections.map(\.title) == ["Hoy", "Marzo 2026", "Sin fecha"])
        #expect(sections.last?.entries.map(\.dir.lastPathComponent) == ["nodate"])
    }

    @Test func aFutureStartIsShownUnderHoy() {
        let sections = ListSections.build([entry("skew", at(2026, 9, 30, 9, 0))], now: now, calendar: calendar)

        #expect(sections.map(\.title) == ["Hoy"])
    }

    @Test func timeZoneDecidesTheDay() {
        // 2026-09-29T02:00Z is still the 28th at UTC-3.
        let instant = Date(timeIntervalSince1970: 1_790_647_200)  // 2026-09-29T02:00:00Z
        let entries = [entry("late", instant)]

        let santiagoLike = ListSections.build(entries, now: now, calendar: calendar)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcNow = utc.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 11))!
        let inUTC = ListSections.build(entries, now: utcNow, calendar: utc)

        #expect(santiagoLike.map(\.title) == ["Ayer"])
        #expect(inUTC.map(\.title) == ["Hoy"])
    }

    @Test func emptyInputYieldsNoSectionsAndOneEntryYieldsOne() {
        #expect(ListSections.build([], now: now, calendar: calendar).isEmpty)
        #expect(ListSections.build([entry("x", at(2026, 9, 29, 9, 0))], now: now, calendar: calendar).count == 1)
    }
}
