import Foundation

@testable import MeetingVox

/// A `ReloadScheduler` a test drives by hand: nothing runs until `fire()`, so
/// "a burst became one scan" is an assertion on counts, not a wait.
@MainActor
final class ManualReloadScheduler {
    struct Entry {
        let delay: TimeInterval
        let work: @MainActor () -> Void
        var cancelled = false
        var fired = false
    }

    private(set) var entries: [Entry] = []

    /// Scheduled and neither cancelled nor run yet.
    var pending: Int { entries.filter { !$0.cancelled && !$0.fired }.count }
    /// How many times anything was scheduled at all.
    var scheduledCount: Int { entries.count }

    var scheduler: ReloadScheduler {
        ReloadScheduler { [self] delay, work in
            let index = entries.count
            entries.append(Entry(delay: delay, work: work))
            return { [self] in entries[index].cancelled = true }
        }
    }

    /// Runs every pending entry once, as the clock reaching the delay would.
    func fire() {
        for index in entries.indices where !entries[index].cancelled && !entries[index].fired {
            entries[index].fired = true
            entries[index].work()
        }
    }
}
