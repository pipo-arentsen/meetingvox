import Foundation

@testable import MeetingVox

/// A scripted `CalendarSource` for tests: never EventKit. Records how often
/// the access request and the event query were called.
actor FakeCalendarSource: CalendarSource {
    private var current: CalendarSystemStatus
    private let grantOnRequest: CalendarSystemStatus
    private let eventsToReturn: [CalendarEventSnapshot]
    private(set) var requestCount = 0
    private(set) var queries: [DateInterval] = []

    init(
        status: CalendarSystemStatus = .authorized, answerToRequest: CalendarSystemStatus = .authorized,
        events: [CalendarEventSnapshot] = []
    ) {
        current = status
        grantOnRequest = answerToRequest
        eventsToReturn = events
    }

    func status() async -> CalendarSystemStatus { current }

    func requestFullAccess() async -> CalendarSystemStatus {
        requestCount += 1
        current = grantOnRequest
        return current
    }

    func events(overlapping interval: DateInterval) async throws -> [CalendarEventSnapshot] {
        queries.append(interval)
        return eventsToReturn
    }
}
