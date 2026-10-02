import Foundation

/// The source of every process that must never touch EventKit: the bare
/// binary, tests, `doctor`, `diag`. It grants nothing and finds nothing.
struct UnavailableCalendarSource: CalendarSource {
    func status() async -> CalendarSystemStatus { .unavailable }
    func requestFullAccess() async -> CalendarSystemStatus { .unavailable }
    func events(overlapping interval: DateInterval) async throws -> [CalendarEventSnapshot] { [] }
}
