import Foundation
import Testing

@testable import MeetingVox

/// Coalescing of the main window's reloads (a pipeline burst = one scan).
@MainActor
@Suite("ReloadDebouncer")
struct ReloadDebouncerTests {
    private final class Runs {
        var count = 0
    }

    private func make(delay: TimeInterval = 0.15) -> (ReloadDebouncer, ManualReloadScheduler, Runs) {
        let manual = ManualReloadScheduler()
        let runs = Runs()
        return (ReloadDebouncer(delay: delay, scheduler: manual.scheduler) { runs.count += 1 }, manual, runs)
    }

    @Test func aBurstOfRequestsRunsTheActionOnceAfterTheDelay() {
        let (debouncer, manual, runs) = make()

        for _ in 0..<5 { debouncer.request() }
        #expect(runs.count == 0, "nothing runs before the delay")
        #expect(manual.pending == 1, "each request replaces the one before")

        manual.fire()
        #expect(runs.count == 1)
        #expect(!debouncer.isPending)
    }

    @Test func theDelayIsPassedToTheScheduler() {
        let (debouncer, manual, _) = make(delay: 0.15)
        debouncer.request()
        #expect(manual.entries.map(\.delay) == [0.15])
    }

    @Test func cancelDropsThePendingRun() {
        let (debouncer, manual, runs) = make()
        debouncer.request()
        #expect(debouncer.isPending)

        debouncer.cancel()
        manual.fire()

        #expect(runs.count == 0)
        #expect(!debouncer.isPending)
    }

    @Test func aRequestAfterTheRunSchedulesAgain() {
        let (debouncer, manual, runs) = make()
        debouncer.request()
        manual.fire()
        debouncer.request()
        manual.fire()
        #expect(runs.count == 2)
        #expect(manual.scheduledCount == 2)
    }

    @Test func cancellingWithNothingPendingIsHarmless() {
        let (debouncer, manual, runs) = make()
        debouncer.cancel()
        manual.fire()
        #expect(runs.count == 0)
    }
}
