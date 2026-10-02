import Foundation
import Network

/// When the Hindsight export sweeps every session: at launch, every 10
/// minutes, when the network comes back, and when settings change (which
/// also lifts a token pause). Event triggers (transcript, minutes, summary
/// done) call the coordinator directly from `AppController`; sweeps are the
/// safety net for outages and missed events.
@MainActor
final class HindsightScheduler {
    nonisolated static let sweepInterval: TimeInterval = 10 * 60

    private let root: URL
    private let coordinator: HindsightCoordinator
    private let notifications: NotificationCenter
    private var timer: Timer?
    private var monitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status?
    private var configObserver: NSObjectProtocol?

    init(root: URL, coordinator: HindsightCoordinator, notifications: NotificationCenter = .default) {
        self.root = root
        self.coordinator = coordinator
        self.notifications = notifications
    }

    func start() {
        guard timer == nil else { return }
        sweep()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        // Delivered on the main queue (cheap: one comparison), same
        // `assumeIsolated` pattern as the notification observers.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.pathChanged(path.status) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
        configObserver = notifications.addObserver(forName: .meetingVoxConfigDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configChanged() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitor?.cancel()
        monitor = nil
        if let configObserver { notifications.removeObserver(configObserver) }
        configObserver = nil
    }

    func sweep() {
        let coordinator = coordinator
        let root = root
        Task { await coordinator.sweep(root: root) }
    }

    /// The first update only reports the current state (the launch sweep
    /// already covered it); only a real transition to `satisfied` sweeps.
    nonisolated static func becameSatisfied(previous: NWPath.Status?, current: NWPath.Status) -> Bool {
        guard let previous else { return false }
        return previous != .satisfied && current == .satisfied
    }

    private func pathChanged(_ status: NWPath.Status) {
        let previous = lastPathStatus
        lastPathStatus = status
        if Self.becameSatisfied(previous: previous, current: status) { sweep() }
    }

    /// New token (the settings window posts this after a Keychain save) or
    /// new config: un-pause, then look at everything again.
    private func configChanged() {
        let coordinator = coordinator
        let root = root
        Task {
            await coordinator.resumeAuth()
            await coordinator.sweep(root: root)
        }
    }
}
