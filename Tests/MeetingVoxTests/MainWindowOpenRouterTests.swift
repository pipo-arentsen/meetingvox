import Foundation
import Testing
@testable import MeetingVox

/// Opening the main window on a session while onboarding holds the starts:
/// the onboarding window comes forward, the requested session (and tab) is
/// remembered — the last request wins — and opens once the starts are released.
@MainActor
@Suite final class MainWindowOpenRouterTests {
    private struct Presented: Equatable {
        let session: URL?
        let tab: DetailTab?
    }

    private final class Log {
        var presented: [Presented] = []
        var onboardingShown = 0
        var banksRefreshed = 0
        var onboardingComes = true
    }

    private let a = URL(fileURLWithPath: "/fake/root/2026.09.29-0900", isDirectory: true)
    private let b = URL(fileURLWithPath: "/fake/root/2026.09.29-1000", isDirectory: true)

    private func make(holding: Bool, _ log: Log) -> (MainWindowOpenRouter, DeferredStarts) {
        let deferred = DeferredStarts(deferring: holding, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let router = MainWindowOpenRouter(
            deferred: deferred,
            showOnboarding: { log.onboardingShown += 1; return log.onboardingComes },
            refreshBanks: { log.banksRefreshed += 1 },
            present: { log.presented.append(Presented(session: $0, tab: $1)) }
        )
        return (router, deferred)
    }

    @Test func withNothingHeldItOpensAtOnceAndRefreshesTheBanks() {
        let log = Log()
        let (router, _) = make(holding: false, log)
        router.open(focusing: a, tab: .minuta)
        #expect(log.presented == [Presented(session: a, tab: .minuta)])
        #expect(log.banksRefreshed == 1)
        #expect(log.onboardingShown == 0)
    }

    @Test func whileOnboardingHoldsTheStartsTheRequestWaitsAndReplaysOnRelease() {
        let log = Log()
        let (router, deferred) = make(holding: true, log)
        router.open(focusing: a, tab: .minuta)

        #expect(log.presented.isEmpty, "the window is not opened over onboarding")
        #expect(log.onboardingShown == 1, "onboarding comes forward")

        deferred.windowClosed()
        #expect(log.presented == [Presented(session: a, tab: .minuta)])
    }

    @Test func theLastRequestWins() {
        let log = Log()
        let (router, deferred) = make(holding: true, log)
        router.open(focusing: a, tab: .minuta)
        router.open(focusing: b, tab: nil)
        deferred.recordingStarted()
        #expect(log.presented == [Presented(session: b, tab: nil)])
        #expect(log.onboardingShown == 2)
    }

    @Test func aPlainOpenWithNoSessionIsNotRememberedSoTheWindowNeverOpensBySelf() {
        let log = Log()
        let (router, deferred) = make(holding: true, log)
        router.open(focusing: nil, tab: nil)
        deferred.windowClosed()
        #expect(log.presented.isEmpty)
        #expect(log.onboardingShown == 1)
    }

    @Test func aPlainOpenDoesNotForgetAnEarlierSessionRequest() {
        let log = Log()
        let (router, deferred) = make(holding: true, log)
        router.open(focusing: a, tab: .transcripcion)
        router.open(focusing: nil, tab: nil)
        deferred.windowClosed()
        #expect(log.presented == [Presented(session: a, tab: .transcripcion)])
    }

    @Test func onboardingThatCannotShowReleasesTheStartsAndTheRequestOpensAtOnce() {
        let log = Log()
        log.onboardingComes = false
        let (router, deferred) = make(holding: true, log)
        router.open(focusing: a, tab: nil)
        #expect(!deferred.isHolding)
        #expect(log.presented == [Presented(session: a, tab: nil)])
    }

    @Test func afterTheReleaseRequestsOpenAtOnce() {
        let log = Log()
        let (router, deferred) = make(holding: true, log)
        deferred.windowClosed()
        router.open(focusing: b, tab: .resumen)
        #expect(log.presented == [Presented(session: b, tab: .resumen)])
        #expect(log.onboardingShown == 0)
    }
}
