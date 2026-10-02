import Foundation

/// Ties the calendar to one recording's lifetime. The recording itself knows
/// nothing about the calendar: `RecordingSession.stop` writes meta.json
/// exactly as without the feature.
///
/// - `recordingStarted`: after the tracks are running, a lookup over the
///   provisional range (start .. start + 10 min) runs in memory only.
/// - `recordingStopped` (NORMAL stop): one follow-up awaits that lookup,
///   refines it with the real end, and writes `refined ?? start match` ONCE
///   (only if the key is absent), then asks for the index to be regenerated.
///   The start match is a fallback only while its event still overlaps the
///   real window; and nothing is written when the integration was turned off
///   or access revoked since the recording started (the gate is checked again
///   at stop). Only this follow-up ever writes, so a lookup that finishes late
///   never does on its own. Quitting right after a normal stop can lose the
///   link: the follow-up is off-main and not awaited by the quit drain.
/// - `recordingTerminated` (signals, logout, quit): cancels the lookup and
///   writes nothing; the quit drain stays synchronous and minimal.
@MainActor
final class CalendarSessionLink {
    /// Writes the record to the session folder; true when meta.json changed
    /// (false: a key was already there).
    typealias Write = @Sendable (CalendarEventRecord, URL) throws -> Bool

    private struct Lookup: Sendable {
        let dir: URL
        let startedAt: Date
        let meetingApp: String?
        let task: Task<CalendarEventRecord?, Never>
    }

    private let linker: CalendarLinker
    private let write: Write
    private let reindex: @Sendable () async -> Void
    private var lookup: Lookup?

    init(linker: CalendarLinker, write: @escaping Write, reindex: @escaping @Sendable () async -> Void) {
        self.linker = linker
        self.write = write
        self.reindex = reindex
    }

    /// Whether a start lookup is held (it is dropped on both stop paths).
    var hasStartLookup: Bool { lookup != nil }

    /// Call after the recording started. Does nothing when the integration is
    /// off: no task, no source call.
    func recordingStarted(dir: URL, startedAt: Date, meetingApp: String?) {
        lookup?.task.cancel()
        lookup = nil
        guard linker.isEnabled() else { return }
        let linker = self.linker
        let provisional = DateInterval(start: startedAt, duration: 10 * 60)
        let task = Task { await linker.match(recording: provisional, meetingApp: meetingApp) }
        lookup = Lookup(dir: dir, startedAt: startedAt, meetingApp: meetingApp, task: task)
    }

    /// Call after a NORMAL stop, once `RecordingSession.stop()` returned.
    /// Returns the off-main follow-up (nil when no lookup was held), which
    /// the caller may ignore; tests await it.
    @discardableResult
    func recordingStopped(endedAt: Date) -> Task<Void, Never>? {
        guard let held = lookup else { return nil }
        lookup = nil
        let (linker, write, reindex) = (self.linker, self.write, self.reindex)
        return Task.detached(priority: .utility) {
            let atStart = await held.task.value
            let real = DateInterval(start: held.startedAt, end: max(endedAt, held.startedAt))
            let refined = await linker.match(recording: real, meetingApp: held.meetingApp)
            // Checked explicitly: a nil refine cannot tell "gate closed" from "no event".
            guard await linker.isAllowed() else { return }
            let stillOverlaps = atStart.flatMap {
                CalendarEventMatcher.overlapsWindow(start: $0.start, end: $0.end, recording: real) ? $0 : nil
            }
            guard let final = refined ?? stillOverlaps else { return }
            do {
                if try write(final, held.dir) { await reindex() }
            } catch {
                FileHandle.standardError.write(Data("calendar: could not link event: \(error)\n".utf8))
            }
        }
    }

    /// Call on the termination path: the lookup is dropped, nothing is written.
    func recordingTerminated() {
        lookup?.task.cancel()
        lookup = nil
    }
}
