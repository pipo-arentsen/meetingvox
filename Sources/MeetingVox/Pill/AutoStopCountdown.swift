import Foundation

/// The end prompt's auto-stop countdown. Pure: callers pass `systemUptime`-style
/// timestamps, so tests need no clock and a wall-clock jump never moves it.
struct AutoStopCountdown: Equatable, Sendable {
    /// Fixed, not configurable: long enough to answer a prompt that appeared
    /// while looking elsewhere, short enough not to leave a finished call recording.
    static let duration: TimeInterval = 45

    private var startedAt: TimeInterval?

    var isRunning: Bool { startedAt != nil }

    mutating func start(at now: TimeInterval) { startedAt = now }

    mutating func cancel() { startedAt = nil }

    /// After a wake the full 45 s start over; a countdown that is not running
    /// stays stopped.
    mutating func restart(at now: TimeInterval) {
        if startedAt != nil { startedAt = now }
    }

    /// Seconds left (never below 0); nil when not running.
    func remaining(at now: TimeInterval) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, Self.duration - (now - startedAt))
    }

    func isExpired(at now: TimeInterval) -> Bool {
        guard let left = remaining(at: now) else { return false }
        return left <= 0
    }

    /// `m:ss` with whole seconds rounded up, so "0:00" only shows at expiry.
    static func text(_ remaining: TimeInterval) -> String {
        let whole = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
