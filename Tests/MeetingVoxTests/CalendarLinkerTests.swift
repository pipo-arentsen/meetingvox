import Foundation
import Testing
@testable import MeetingVox

@Suite struct CalendarLinkerTests {
    private let recording = DateInterval(start: CalendarFixtures.at(0), end: CalendarFixtures.at(30))

    private func linker(
        _ source: any CalendarSource, enabled: Bool = true
    ) -> CalendarLinker {
        CalendarLinker(source: source, isEnabled: { enabled }, now: { CalendarFixtures.at(31) })
    }

    @Test func matchesAnEventWhenEnabledAndAuthorized() async {
        let source = FakeCalendarSource(status: .authorized, events: [CalendarFixtures.snapshot(title: "Weekly")])
        let record = await linker(source).match(recording: recording, meetingApp: nil)
        #expect(record?.title == "Weekly")
        #expect(record?.matchedAt == CalendarFixtures.at(31))
        #expect(await source.queries.count == 1)
    }

    @Test func disabledTouchesNothing() async {
        let source = FakeCalendarSource(status: .authorized, events: [CalendarFixtures.snapshot()])
        let record = await linker(source, enabled: false).match(recording: recording, meetingApp: nil)
        #expect(record == nil)
        #expect(await source.queries.isEmpty)
        #expect(await source.requestCount == 0)
    }

    @Test(arguments: [CalendarSystemStatus.denied, .restricted, .notDetermined, .writeOnly, .unavailable])
    func notAuthorizedNeverQueriesNorRequests(status: CalendarSystemStatus) async {
        let source = FakeCalendarSource(status: status, events: [CalendarFixtures.snapshot()])
        let record = await linker(source).match(recording: recording, meetingApp: nil)
        #expect(record == nil)
        #expect(await source.queries.isEmpty)
        #expect(await source.requestCount == 0)
    }

    @Test func grantedLaterMatchesWithoutRetoggling() async {
        // The same linker, status flips to authorized between two recordings.
        let source = FakeCalendarSource(status: .denied, answerToRequest: .authorized, events: [CalendarFixtures.snapshot()])
        let l = linker(source)
        #expect(await l.match(recording: recording, meetingApp: nil) == nil)
        _ = await source.requestFullAccess() // the user grants it in System Settings
        #expect(await l.match(recording: recording, meetingApp: nil) != nil)
    }

    @Test func unavailableSourceIsNil() async {
        let record = await linker(UnavailableCalendarSource()).match(recording: recording, meetingApp: nil)
        #expect(record == nil)
    }

    @Test func queryWindowStartsTenMinutesBeforeTheRecording() async {
        let source = FakeCalendarSource(status: .authorized, events: [])
        _ = await linker(source).match(recording: recording, meetingApp: "zoom")
        let query = await source.queries.first
        #expect(query?.start == CalendarFixtures.at(-10))
        #expect(query?.end == CalendarFixtures.at(30))
    }

    @Test func prefersTheMeetingAppHost() async {
        let plain = CalendarFixtures.snapshot(id: "a", title: "Plain")
        let zoom = CalendarFixtures.snapshot(id: "b", title: "Zoom call", videoURLs: [URL(string: "https://example.zoom.us/j/123")!])
        let source = FakeCalendarSource(status: .authorized, events: [plain, zoom])
        let record = await linker(source).match(recording: recording, meetingApp: "zoom")
        #expect(record?.title == "Zoom call")
    }
}

/// A source whose query never answers on its own (it only ends when cancelled).
private actor HangingSource: CalendarSource {
    func status() async -> CalendarSystemStatus { .authorized }
    func requestFullAccess() async -> CalendarSystemStatus { .authorized }
    func events(overlapping interval: DateInterval) async throws -> [CalendarEventSnapshot] {
        try await Task.sleep(for: .seconds(3_600))
        return []
    }
}

/// Answers after a short delay.
private actor SlowSource: CalendarSource {
    func status() async -> CalendarSystemStatus { .authorized }
    func requestFullAccess() async -> CalendarSystemStatus { .authorized }
    func events(overlapping interval: DateInterval) async throws -> [CalendarEventSnapshot] {
        try await Task.sleep(for: .milliseconds(20))
        return [CalendarFixtures.snapshot(title: "Slow but fine")]
    }
}

@Suite struct CalendarLinkerTimeoutTests {
    private let recording = DateInterval(start: CalendarFixtures.at(0), end: CalendarFixtures.at(30))

    @Test func aQueryThatNeverAnswersTimesOutToNil() async {
        let linker = CalendarLinker(
            source: HangingSource(), isEnabled: { true }, queryTimeout: .milliseconds(50),
            now: { CalendarFixtures.at(31) })
        let started = ContinuousClock.now
        let record = await linker.match(recording: recording, meetingApp: nil)
        #expect(record == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aQueryWithinTheTimeoutStillMatches() async {
        let linker = CalendarLinker(
            source: SlowSource(), isEnabled: { true }, queryTimeout: .seconds(5), now: { CalendarFixtures.at(31) })
        #expect(await linker.match(recording: recording, meetingApp: nil)?.title == "Slow but fine")
    }

    @Test func cancellingTheCallerEndsAHangingQueryAtOnce() async {
        let linker = CalendarLinker(
            source: HangingSource(), isEnabled: { true }, queryTimeout: .seconds(3_600), now: { CalendarFixtures.at(31) })
        let rec = recording
        let task = Task { await linker.match(recording: rec, meetingApp: nil) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == nil)
    }
}
