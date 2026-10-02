import Foundation
import Testing
@testable import MeetingVox

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

private func entry(_ name: String, _ started: String?) -> MeetingEntry {
    MeetingEntry(
        dir: URL(fileURLWithPath: "/tmp/\(name)"), started: started.map(date), durationSeconds: nil, app: nil,
        summary: nil, hasMinutes: false, hasTranscript: true
    )
}

@Suite struct MeetingWindowTests {
    private let now = date("2026-09-27T12:00:00Z")

    @Test func cutoffIs30DaysFromTodayThenOneCalendarMonthPerStep() {
        #expect(MeetingWindow.cutoff(extraMonths: 0, now: now, calendar: utc) == date("2026-08-28T00:00:00Z"))
        #expect(MeetingWindow.cutoff(extraMonths: 1, now: now, calendar: utc) == date("2026-07-28T00:00:00Z"))
        #expect(MeetingWindow.cutoff(extraMonths: 3, now: now, calendar: utc) == date("2026-05-28T00:00:00Z"))
    }

    @Test func candidatesAreTheWindowUnlessSearching() {
        let entries = [
            entry("a", "2026-09-20T10:00:00Z"), entry("b", "2026-08-15T10:00:00Z"), entry("undated", nil),
        ]
        let cutoff = MeetingWindow.cutoff(extraMonths: 0, now: now, calendar: utc)
        #expect(MeetingWindow.candidates(entries, query: "", client: nil, cutoff: cutoff).map(\.dir.lastPathComponent)
            == ["a", "undated"])
        #expect(MeetingWindow.candidates(entries, query: "  ", client: "", cutoff: cutoff).count == 2)
        #expect(MeetingWindow.candidates(entries, query: "x", client: nil, cutoff: cutoff).count == 3)
        #expect(MeetingWindow.candidates(entries, query: "", client: "Proveedor", cutoff: cutoff).count == 3)
    }

    @Test func hasOlderIgnoresUndatedSessions() {
        let cutoff = MeetingWindow.cutoff(extraMonths: 0, now: now, calendar: utc)
        #expect(MeetingWindow.hasOlder([entry("b", "2026-08-15T10:00:00Z")], cutoff: cutoff))
        #expect(!MeetingWindow.hasOlder([entry("a", "2026-09-20T10:00:00Z"), entry("u", nil)], cutoff: cutoff))
    }

    @Test func anAmbitoOrTypeFilterSearchesEverySession() {
        let entries = [entry("a", "2026-09-20T10:00:00Z"), entry("b", "2026-08-15T10:00:00Z")]
        let cutoff = MeetingWindow.cutoff(extraMonths: 0, now: now, calendar: utc)
        #expect(MeetingWindow.candidates(entries, query: "", client: nil, ambito: .unclassified, cutoff: cutoff).count == 2)
        #expect(MeetingWindow.candidates(entries, query: "", client: nil, type: .noMinutes, cutoff: cutoff).count == 2)
        #expect(MeetingWindow.candidates(entries, query: "", client: nil, ambito: .all, type: nil, cutoff: cutoff).count == 1)
        #expect(MeetingWindow.isSearching(query: "", client: nil, ambito: .only(.personal)))
        #expect(!MeetingWindow.isSearching(query: " ", client: "", ambito: .all, type: nil))
    }
}
