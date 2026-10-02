import Foundation
import Testing

@testable import MeetingVox

/// EventKit exists only in the bundled app. These tests never build the
/// EventKit source (`make(isBundled: true)` is never called here).
@Suite struct CalendarSourcesTests {
    @Test func anUnbundledProcessGetsTheUnavailableSource() async throws {
        let source = CalendarSources.make(isBundled: false)
        #expect(source is UnavailableCalendarSource)
        #expect(await source.status() == .unavailable)
        #expect(await source.requestFullAccess() == .unavailable)
        let events = try await source.events(overlapping: DateInterval(start: .now, duration: 3600))
        #expect(events.isEmpty)
    }

    @Test func theUnavailableSourceNeverReportsAccessWhatevertheCaller() async {
        let source = UnavailableCalendarSource()
        // Asking repeatedly changes nothing: there is nothing to grant.
        for _ in 0..<3 { #expect(await source.requestFullAccess() == .unavailable) }
        #expect(!CalendarAccess.effective(enabled: true, system: await source.status()))
    }

    @Test func theFakeSourceAnswersAsScriptedAndCountsRequests() async throws {
        let snapshot = CalendarFixtures.snapshot(id: "x")
        let fake = FakeCalendarSource(status: .notDetermined, answerToRequest: .authorized, events: [snapshot])
        let source: any CalendarSource = fake
        #expect(await source.status() == .notDetermined)
        #expect(await source.requestFullAccess() == .authorized)
        #expect(await source.status() == .authorized)
        let interval = DateInterval(start: CalendarFixtures.at(0), duration: 600)
        #expect(try await source.events(overlapping: interval) == [snapshot])
        #expect(await fake.requestCount == 1)
        #expect(await fake.queries == [interval])
    }
}
