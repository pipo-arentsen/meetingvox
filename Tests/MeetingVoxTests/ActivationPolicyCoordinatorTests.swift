import Testing

@testable import MeetingVox

/// Ref-counted activation policy: `.regular` (Dock icon) while any holder
/// needs a window, `.accessory` otherwise. The applier is injected, so
/// nothing here touches `NSApp`.
@MainActor
@Suite("ActivationPolicyCoordinator")
struct ActivationPolicyCoordinatorTests {
    private final class Applied {
        var policies: [ActivationPolicyCoordinator.Policy] = []
    }

    private func make() -> (ActivationPolicyCoordinator, Applied) {
        let applied = Applied()
        return (ActivationPolicyCoordinator { applied.policies.append($0) }, applied)
    }

    @Test func nothingIsAppliedUntilSomeoneAcquires() {
        let (coordinator, applied) = make()
        #expect(applied.policies.isEmpty)
        #expect(coordinator.holders == 0)
    }

    @Test func theFirstAcquireSwitchesToRegular() {
        let (coordinator, applied) = make()
        let lease = coordinator.acquire()
        #expect(applied.policies == [.regular])
        #expect(coordinator.holders == 1)
        lease.release()
    }

    @Test func releasingTheOnlyHolderReturnsToAccessory() {
        let (coordinator, applied) = make()
        let lease = coordinator.acquire()
        lease.release()
        #expect(applied.policies == [.regular, .accessory])
        #expect(coordinator.holders == 0)
    }

    @Test func nestedHoldersKeepRegularUntilTheLastOneReleases() {
        let (coordinator, applied) = make()
        let first = coordinator.acquire()
        let second = coordinator.acquire()
        #expect(applied.policies == [.regular])
        #expect(coordinator.holders == 2)
        first.release()
        #expect(applied.policies == [.regular])
        #expect(coordinator.holders == 1)
        second.release()
        #expect(applied.policies == [.regular, .accessory])
    }

    @Test func aDoubleReleaseIsIdempotent() {
        let (coordinator, applied) = make()
        let first = coordinator.acquire()
        let second = coordinator.acquire()
        first.release()
        first.release()
        first.release()
        #expect(coordinator.holders == 1)
        #expect(applied.policies == [.regular])
        second.release()
        second.release()
        #expect(coordinator.holders == 0)
        #expect(applied.policies == [.regular, .accessory])
    }

    @Test func theCountNeverGoesNegativeAndTheNextAcquireStillSwitches() {
        let (coordinator, applied) = make()
        let lease = coordinator.acquire()
        lease.release()
        lease.release()
        #expect(coordinator.holders == 0)
        let again = coordinator.acquire()
        #expect(coordinator.holders == 1)
        #expect(applied.policies == [.regular, .accessory, .regular])
        again.release()
    }

    @Test func aReleasedLeaseCannotStealAnotherHoldersCount() {
        let (coordinator, applied) = make()
        let stale = coordinator.acquire()
        stale.release()
        let live = coordinator.acquire()
        stale.release()
        #expect(coordinator.holders == 1)
        #expect(applied.policies == [.regular, .accessory, .regular])
        live.release()
        #expect(applied.policies.last == .accessory)
    }

    @Test func aLeaseDroppedWithoutReleaseGivesBackItsHold() {
        let (coordinator, applied) = make()
        var lease: ActivationPolicyCoordinator.Lease? = coordinator.acquire()
        #expect(lease != nil)
        #expect(coordinator.holders == 1)
        lease = nil
        #expect(coordinator.holders == 0)
        #expect(applied.policies == [.regular, .accessory])
    }

    @Test func aLeaseReleasedThenDroppedDoesNotReleaseTwice() {
        let (coordinator, applied) = make()
        let other = coordinator.acquire()
        var lease: ActivationPolicyCoordinator.Lease? = coordinator.acquire()
        lease?.release()
        #expect(coordinator.holders == 1)
        lease = nil
        #expect(coordinator.holders == 1)
        #expect(applied.policies == [.regular])
        other.release()
        #expect(applied.policies == [.regular, .accessory])
    }
}
