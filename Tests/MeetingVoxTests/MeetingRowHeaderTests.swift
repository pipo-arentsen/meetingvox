import Foundation
import Testing
@testable import MeetingVox

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
private let utc = TimeZone(identifier: "UTC")!

@Suite struct MeetingRowHeaderTests {
    @Test func dayDateStartEndAndDuration() {
        #expect(MeetingRowHeader.text(
            started: date("2026-09-24T10:53:00Z"), ended: date("2026-09-24T11:05:00Z"), durationSeconds: 720, timeZone: utc
        ) == "Jue 24 sep · 10:53–11:05 (12 min)")
    }

    @Test func withoutEndedTheDurationGivesTheEnd() {
        #expect(MeetingRowHeader.text(
            started: date("2026-09-24T10:53:00Z"), ended: nil, durationSeconds: 720, timeZone: utc
        ) == "Jue 24 sep · 10:53–11:05 (12 min)")
    }

    @Test func withoutAnyEndOnlyTheStartShows() {
        #expect(MeetingRowHeader.text(
            started: date("2026-09-24T10:53:00Z"), ended: nil, durationSeconds: nil, timeZone: utc
        ) == "Jue 24 sep · 10:53")
    }

    @Test func crossingMidnightKeepsTheStartDay() {
        #expect(MeetingRowHeader.text(
            started: date("2026-09-24T23:50:00Z"), ended: date("2026-09-25T00:10:00Z"), durationSeconds: 1200, timeZone: utc
        ) == "Jue 24 sep · 23:50–00:10 (20 min)")
    }

    @Test func usesTheLocalTimeZoneForDayAndTimes() {
        let chile = TimeZone(secondsFromGMT: -3 * 3600)!
        #expect(MeetingRowHeader.text(
            started: date("2026-09-24T13:53:00Z"), ended: date("2026-09-24T14:05:00Z"), durationSeconds: 720, timeZone: chile
        ) == "Jue 24 sep · 10:53–11:05 (12 min)")
        // 01:30 UTC on Friday is still Thursday evening locally.
        #expect(MeetingRowHeader.text(
            started: date("2026-09-25T01:30:00Z"), ended: nil, durationSeconds: 1800, timeZone: chile
        ) == "Jue 24 sep · 22:30–23:00 (30 min)")
    }

    @Test func anEndBeforeTheStartIsIgnored() {
        #expect(MeetingRowHeader.text(
            started: date("2026-09-24T10:53:00Z"), ended: date("2026-09-24T10:00:00Z"), durationSeconds: 720, timeZone: utc
        ) == "Jue 24 sep · 10:53–11:05 (12 min)")
    }

    @Test func longAndVeryShortDurations() {
        let start = date("2026-09-24T10:53:00Z")
        #expect(MeetingRowHeader.text(started: start, ended: nil, durationSeconds: 3900, timeZone: utc)
            == "Jue 24 sep · 10:53–11:58 (1 h 5 min)")
        #expect(MeetingRowHeader.text(started: start, ended: nil, durationSeconds: 7200, timeZone: utc)
            == "Jue 24 sep · 10:53–12:53 (2 h)")
        #expect(MeetingRowHeader.text(started: start, ended: nil, durationSeconds: 20, timeZone: utc)
            == "Jue 24 sep · 10:53–10:53 (<1 min)")
    }

    @Test func noStartNoHeader() {
        #expect(MeetingRowHeader.text(started: nil, ended: nil, durationSeconds: 600, timeZone: utc) == nil)
    }
}
