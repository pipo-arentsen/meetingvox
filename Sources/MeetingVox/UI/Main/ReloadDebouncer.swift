import Foundation

/// How the main window waits before rescanning. A closure pair rather than a
/// protocol so a test hands in one that runs only when told to. `schedule`
/// runs `work` after `delay` seconds on the main actor and returns a closure
/// that cancels it.
struct ReloadScheduler {
    let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> @MainActor () -> Void

    /// A cancellable `Task.sleep` on the main actor.
    static let live = ReloadScheduler { delay, work in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            work()
        }
        return { task.cancel() }
    }
}

/// Coalesces a burst of "the disk probably changed" signals (a pipeline stage
/// ending, an index notification, a Hindsight status) into one action after a
/// quiet `delay`: each request replaces the pending one.
@MainActor
final class ReloadDebouncer {
    static let defaultDelay: TimeInterval = 0.15

    private let delay: TimeInterval
    private let scheduler: ReloadScheduler
    private let action: @MainActor () -> Void
    private var cancelPending: (@MainActor () -> Void)?

    init(delay: TimeInterval = ReloadDebouncer.defaultDelay, scheduler: ReloadScheduler = .live, action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.scheduler = scheduler
        self.action = action
    }

    var isPending: Bool { cancelPending != nil }

    func request() {
        cancelPending?()
        cancelPending = scheduler.schedule(delay) { [weak self] in
            guard let self else { return }
            self.cancelPending = nil
            self.action()
        }
    }

    func cancel() {
        cancelPending?()
        cancelPending = nil
    }
}
