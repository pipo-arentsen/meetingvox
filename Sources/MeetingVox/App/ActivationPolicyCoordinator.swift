import AppKit

/// Ref-counted switch between `.regular` (Dock icon, app switcher, a window
/// that can take focus) and `.accessory` (menu bar only).
///
/// The app runs as `.accessory`; any window that needs to be a proper
/// window (onboarding now, the main window in a later change) takes a
/// `Lease` while it is open. The first lease turns the Dock icon on, the
/// last release turns it off, so two windows never fight over the policy.
@MainActor
final class ActivationPolicyCoordinator {
    enum Policy: Equatable {
        case regular
        case accessory
    }

    /// One holder's claim. Releasing twice, or releasing a lease that was
    /// already released, does nothing, so a window can release on every
    /// path (close, failure, teardown) without counting.
    @MainActor
    final class Lease {
        private var coordinator: ActivationPolicyCoordinator?

        fileprivate init(_ coordinator: ActivationPolicyCoordinator) {
            self.coordinator = coordinator
        }

        func release() {
            guard let coordinator else { return }
            self.coordinator = nil
            coordinator.releaseOne()
        }

        /// Safety net: a window that forgot to release (or was torn down
        /// without its close path) must not pin the Dock icon on. Idempotent
        /// with an explicit `release()`, which already cleared `coordinator`.
        isolated deinit {
            release()
        }
    }

    /// The app-wide coordinator: `.regular` also activates the app, since an
    /// `.accessory` process is not frontmost and its window would open
    /// behind whatever the user was doing.
    static let shared = ActivationPolicyCoordinator { policy in
        switch policy {
        case .regular:
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        case .accessory:
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private let apply: @MainActor (Policy) -> Void
    private(set) var holders = 0

    init(apply: @escaping @MainActor (Policy) -> Void) {
        self.apply = apply
    }

    func acquire() -> Lease {
        holders += 1
        if holders == 1 { apply(.regular) }
        return Lease(self)
    }

    private func releaseOne() {
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0 { apply(.accessory) }
    }
}
