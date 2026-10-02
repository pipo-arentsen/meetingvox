import Foundation

/// Finds the calendar event a recording belongs to. The effective gate lives
/// here (`CalendarAccess.effective`): nothing is read unless the integration is
/// enabled AND the system already granted full access, and the linker never
/// asks for access (only the settings toggle does). Not enabled, not
/// authorized, a failing or hanging source or a cancelled task all answer nil.
actor CalendarLinker {
    /// `calendar.enabled`, read synchronously by the caller each time (the
    /// setting can change between recordings). A closure so this type never
    /// touches the config file itself.
    nonisolated let isEnabled: @Sendable () -> Bool

    private let source: any CalendarSource
    private let queryTimeout: Duration
    private let now: @Sendable () -> Date

    init(
        source: any CalendarSource, isEnabled: @escaping @Sendable () -> Bool,
        queryTimeout: Duration = .seconds(10), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.isEnabled = isEnabled
        self.queryTimeout = queryTimeout
        self.now = now
    }

    /// The gate: enabled now AND the system status is authorized now.
    func isAllowed() async -> Bool {
        CalendarAccess.effective(enabled: isEnabled(), system: await source.status())
    }

    /// The best event for a recording spanning `recording` (the start lookup
    /// passes a provisional end), or nil.
    func match(recording: DateInterval, meetingApp: String?) async -> CalendarEventRecord? {
        guard await isAllowed(), !Task.isCancelled else { return nil }
        guard let events = await boundedEvents(in: CalendarEventMatcher.window(for: recording)), !Task.isCancelled else {
            return nil
        }
        guard let best = CalendarEventMatcher.pick(from: events, recording: recording, meetingApp: meetingApp) else {
            return nil
        }
        return CalendarEventRecord(snapshot: best, matchedAt: now())
    }

    /// One events query that cannot hang the follow-up: nil on a source error,
    /// on the timeout (one log line) or when the caller is cancelled. Raced
    /// through a rendezvous instead of a task group, because a group would
    /// wait for a source that ignores cancellation.
    private func boundedEvents(in window: DateInterval) async -> [CalendarEventSnapshot]? {
        let (source, timeout) = (self.source, queryTimeout)
        let rendezvous = Rendezvous()
        let work = Task { _ = rendezvous.finish(try? await source.events(overlapping: window)) }
        let timer = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            if rendezvous.finish(nil) {
                FileHandle.standardError.write(Data("calendar: events query timed out after \(timeout)\n".utf8))
            }
        }
        let result = await withTaskCancellationHandler {
            await rendezvous.wait()
        } onCancel: {
            _ = rendezvous.finish(nil)
        }
        work.cancel()
        timer.cancel()
        return result
    }
}

/// First answer wins; later ones are ignored. Resumed exactly once.
private final class Rendezvous: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[CalendarEventSnapshot]?, Never>?
    private var outcome: [CalendarEventSnapshot]??

    /// True when this call decided the outcome.
    func finish(_ value: [CalendarEventSnapshot]?) -> Bool {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return false
        }
        outcome = .some(value)
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
        return true
    }

    func wait() async -> [CalendarEventSnapshot]? {
        await withCheckedContinuation { (waiting: CheckedContinuation<[CalendarEventSnapshot]?, Never>) in
            lock.lock()
            if let decided = outcome {
                lock.unlock()
                waiting.resume(returning: decided)
            } else {
                continuation = waiting
                lock.unlock()
            }
        }
    }
}
