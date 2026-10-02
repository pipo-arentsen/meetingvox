import Foundation

/// Where calendar events come from. The seam keeps EventKit out of the pure
/// core, of tests and of every unbundled process: only
/// `EventKitCalendarSource` talks to the OS, and `CalendarSources.make`
/// hands a real one only to the bundled app.
protocol CalendarSource: Sendable {
    /// The current authorization. Never prompts.
    func status() async -> CalendarSystemStatus
    /// Raises the one system prompt when the status is `.notDetermined`;
    /// otherwise just reports the status (never a second prompt). Calls made
    /// while a request is in flight share it.
    func requestFullAccess() async -> CalendarSystemStatus
    /// Events overlapping `interval`, as Sendable snapshots. Empty without
    /// full access. Read-only: calendars are never written.
    func events(overlapping interval: DateInterval) async throws -> [CalendarEventSnapshot]
}
