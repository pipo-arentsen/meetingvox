import AppKit
import Foundation
import Testing
@testable import MeetingVox

private let cutoff = ISO8601DateFormatter().date(from: "2026-09-29T09:00:00Z")!
private let after = cutoff.addingTimeInterval(3_600)
private let before = cutoff.addingTimeInterval(-3_600)

private func makeFacts(
    started: Date? = after, minutes: SessionSettlement.MarkerState = .done,
    summary: SessionSettlement.MarkerState = .done, memory: HindsightStatus? = nil,
    settledAt: Date? = after, transcript: Bool = true, canSend: Bool = true
) -> SessionSettlement.Facts {
    SessionSettlement.Facts(
        started: started, label: "Kickoff", hasTranscript: transcript, minutes: minutes, summary: summary,
        memory: memory, contentSettledAt: settledAt, memoryCanSend: canSend
    )
}

/// Every seam of `SettlementNotifier`, recorded in one ordered event list.
@MainActor
private final class Harness {
    var events: [String] = []
    var posts: [Notice] = []
    var claims: [URL] = []
    var reads: [URL] = []
    var pausedSeen: [Bool] = []
    var scheduled: [(Date, @MainActor () -> Void)] = []
    var logs: [String] = []
    var now = after
    var hasKey = true
    var config = ConfigValues(raw: ["openrouter": ["model": "m/x"]])
    var facts: (URL) -> SessionSettlement.Facts = { _ in makeFacts() }
    var claim: (URL) -> SessionFiles.ClaimResult = { _ in .claimed }
    var cutoffValue = cutoff
    private(set) var notifier: SettlementNotifier!

    init() {
        notifier = SettlementNotifier(environment: .init(
            config: { [unowned self] in config },
            hasOpenRouterKey: { [unowned self] in hasKey },
            cutoff: { [unowned self] in events.append("cutoff"); return cutoffValue },
            now: { [unowned self] in now },
            readFacts: { [unowned self] dir, _, paused in
                events.append("read"); reads.append(dir); pausedSeen.append(paused)
                return facts(dir)
            },
            claim: { [unowned self] dir in events.append("claim"); claims.append(dir); return claim(dir) },
            post: { [unowned self] notice in events.append("post"); posts.append(notice) },
            schedule: { [unowned self] date, action in scheduled.append((date, action)) },
            log: { [unowned self] in logs.append($0) }
        ))
    }
}

private let dir = URL(fileURLWithPath: "/tmp/rec/2026.09.29-1030", isDirectory: true)

@MainActor
@Suite struct SettlementNotifierTests {
    // MARK: - Settled -> claim -> one post

    @Test func aSettledSessionClaimsThenPostsOneReadyNotice() {
        let h = Harness()
        h.notifier.evaluate(dir)

        #expect(h.events == ["cutoff", "read", "claim", "post"])
        #expect(h.posts.count == 1)
        let notice = h.posts[0]
        #expect(notice.kind == .ready(memoryAction: false))
        #expect(notice.session == dir)
        #expect(notice.title == Textos.Notificacion.reunionLista)
        #expect(notice.body == Textos.Notificacion.reunionListaCuerpo(
            "Kickoff", partes: ["transcripción", "minuta", "resumen"]
        ))
    }

    @Test func theReadyNoticeOffersMemoryWhenTheSessionIsNotInMemory() {
        let h = Harness()
        h.facts = { _ in makeFacts(memory: .notSent) }
        h.notifier.evaluate(dir)
        #expect(h.posts.first?.kind == .ready(memoryAction: true))
    }

    // MARK: - At most once

    @Test func s2AnExistingClaimPostsNothing() {
        let h = Harness()
        h.claim = { _ in .alreadyClaimed }
        h.notifier.evaluate(dir)
        #expect(h.claims == [dir])
        #expect(h.posts.isEmpty)
    }

    @Test func s3TwoSettledEvaluationsPostExactlyOnceWithTheRealClaim() throws {
        let fixture = try SessionFixture()
        let real = try fixture.session("2026.09.29-1030", transcript: false, pending: false)
        let h = Harness()
        h.claim = { SessionFiles.claim(SessionFiles.readyNotified, in: $0) }

        h.notifier.evaluate(real)
        h.notifier.evaluate(real)

        #expect(h.posts.count == 1)
        #expect(SessionFiles.exists(SessionFiles.readyNotified, in: real))
    }

    @Test func s4TheClaimIsNotReleasedSoAnUndeliveredPostIsNotRetried() throws {
        // The post seam cannot report failure or denial: the claim was taken
        // before it, and stays, so a later evaluation posts nothing more.
        let fixture = try SessionFixture()
        let real = try fixture.session("2026.09.29-1030", transcript: false, pending: false)
        let h = Harness()
        h.claim = { SessionFiles.claim(SessionFiles.readyNotified, in: $0) }

        h.notifier.evaluate(real)
        #expect(h.posts.count == 1)
        h.notifier.evaluate(real)
        h.notifier.evaluate(real)

        #expect(h.posts.count == 1)
        #expect(SessionFiles.exists(SessionFiles.readyNotified, in: real))
    }

    @Test func aClaimErrorPostsNothingAndIsLogged() {
        let h = Harness()
        h.claim = { _ in .failed(ENOSPC) }
        h.notifier.evaluate(dir)
        #expect(h.posts.isEmpty)
        #expect(h.logs.count == 1)
    }

    // MARK: - A user-requested "Minuta lista" takes the claim without posting

    @Test func aQuietClaimTakesTheReadyClaimWithoutPostingAnything() {
        let h = Harness()
        h.notifier.claimReadyNotice(dir)
        #expect(h.events == ["cutoff", "read", "claim"])
        #expect(h.claims == [dir])
        #expect(h.posts.isEmpty)
    }

    @Test func aQuietClaimLeavesNothingForTheSettlementCheckToPost() throws {
        let fixture = try SessionFixture()
        let real = try fixture.session("2026.09.29-1030", transcript: false, pending: false)
        let h = Harness()
        h.claim = { SessionFiles.claim(SessionFiles.readyNotified, in: $0) }

        h.notifier.claimReadyNotice(real)
        h.notifier.evaluate(real)

        #expect(SessionFiles.exists(SessionFiles.readyNotified, in: real))
        #expect(h.posts.isEmpty)
    }

    @Test func aQuietClaimForASessionBeforeTheCutoffNeverClaims() {
        let h = Harness()
        h.facts = { _ in makeFacts(started: before) }
        h.notifier.claimReadyNotice(dir)
        #expect(h.claims.isEmpty)
        #expect(h.posts.isEmpty)
    }

    @Test func aQuietClaimForASessionWithoutAStartDateNeverClaims() {
        let h = Harness()
        h.facts = { _ in makeFacts(started: nil) }
        h.notifier.claimReadyNotice(dir)
        #expect(h.claims.isEmpty)
    }

    @Test func aQuietClaimOnAnAlreadyNotifiedSessionIsNotEvenRead() throws {
        let fixture = try SessionFixture()
        let notified = try fixture.session("2026.09.29-1030", transcript: false, pending: false)
        try SessionFiles.writeMarker(SessionFiles.readyNotified, in: notified)
        let h = Harness()

        h.notifier.claimReadyNotice(notified)

        #expect(h.reads.isEmpty)
        #expect(h.claims.isEmpty)
    }

    @Test func aQuietClaimErrorIsLoggedAndNothingIsPosted() {
        let h = Harness()
        h.claim = { _ in .failed(ENOSPC) }
        h.notifier.claimReadyNotice(dir)
        #expect(h.logs.count == 1)
        #expect(h.posts.isEmpty)
    }

    // MARK: - already notified: not even read

    /// The launch sweep and every stage callback look at sessions that were
    /// notified long ago: with `listo.notificado` on disk there is nothing
    /// to decide, so no facts are read (a Hindsight transcript decode each).
    @Test func anAlreadyNotifiedSessionIsNotEvenRead() throws {
        let fixture = try SessionFixture()
        let notified = try fixture.session("2026.09.29-1030", transcript: false, pending: false)
        try SessionFiles.writeMarker(SessionFiles.readyNotified, in: notified)
        let h = Harness()

        h.notifier.evaluate(notified)

        #expect(h.reads.isEmpty)
        #expect(h.claims.isEmpty)
        #expect(h.posts.isEmpty)
    }

    @Test func theLaunchSweepSkipsNotifiedSessionsWithoutStopping() throws {
        let fixture = try SessionFixture()
        let newer = try fixture.session("2026.09.29-1200", transcript: false, pending: false)
        try SessionFiles.writeMarker(SessionFiles.readyNotified, in: newer)
        _ = try fixture.session("2026.09.29-1000", transcript: false, pending: false)
        let h = Harness()

        h.notifier.evaluatePending(root: fixture.root)

        #expect(h.reads.map(\.lastPathComponent) == ["2026.09.29-1000"])
        #expect(h.posts.count == 1)
    }

    // MARK: - Terminal-settled secondary failures, minutes failure stays alone

    @Test func aFailedSummaryStillClaimsAndPostsTheReadyNoticeNamingIt() {
        let h = Harness()
        h.facts = { _ in makeFacts(summary: .failed) }
        h.notifier.evaluate(dir)
        #expect(h.events == ["cutoff", "read", "claim", "post"])
        #expect(h.posts.count == 1)
        #expect(h.posts[0].body == Textos.Notificacion.reunionListaCuerpo(
            "Kickoff", partes: ["transcripción", "minuta"], fallos: [Textos.Notificacion.fallaResumen]
        ))
    }

    @Test func aRejectedMemoryStillPostsTheReadyNoticeNamingIt() {
        let h = Harness()
        h.facts = { _ in makeFacts(memory: .error) }
        h.notifier.evaluate(dir)
        #expect(h.posts.count == 1)
        #expect(h.posts[0].body == Textos.Notificacion.reunionListaCuerpo(
            "Kickoff", partes: ["transcripción", "minuta", "resumen"], fallos: [Textos.Notificacion.fallaMemoria]
        ))
    }

    @Test func aPermanentMinutesFailureNeverClaimsNorPostsReady() {
        let h = Harness()
        h.facts = { _ in makeFacts(minutes: .failed) }
        h.notifier.evaluate(dir)
        #expect(h.claims.isEmpty)
        #expect(h.posts.isEmpty)
    }

    @Test func aSuccessfulMinutesRetryAfterTheFailureStillPostsReady() {
        let h = Harness()
        h.facts = { _ in makeFacts(minutes: .failed) }
        h.notifier.evaluate(dir)
        #expect(h.posts.isEmpty)
        h.facts = { _ in makeFacts(minutes: .done) }
        h.notifier.evaluate(dir)
        #expect(h.posts.count == 1)
    }

    // MARK: - Memory attempts

    @Test func anAttemptSettlesASessionThatWasWaitingForMemory() {
        let h = Harness()
        h.now = after.addingTimeInterval(60)
        // A transient failure leaves the status pending.
        h.facts = { _ in makeFacts(memory: .pending, settledAt: after) }
        h.notifier.evaluate(dir)
        #expect(h.posts.isEmpty)

        h.notifier.didAttempt(dir, authPaused: false)

        #expect(h.posts.count == 1)
        #expect(h.posts[0].kind == .ready(memoryAction: false))
    }

    @Test func anAttemptOnlyCountsForThatSession() {
        let h = Harness()
        h.now = after.addingTimeInterval(60)
        h.facts = { _ in makeFacts(memory: .pending, settledAt: after) }
        let other = URL(fileURLWithPath: "/tmp/rec/2026.09.29-1100", isDirectory: true)
        h.notifier.didAttempt(other, authPaused: false)
        h.posts.removeAll()
        h.notifier.evaluate(dir)
        #expect(h.posts.isEmpty)
    }

    @Test func nothingToSendMeansNoWaitAndNoTimer() {
        let h = Harness()
        h.now = after.addingTimeInterval(60)
        h.facts = { _ in makeFacts(memory: .pending, settledAt: after, canSend: false) }
        h.notifier.evaluate(dir)
        #expect(h.posts.count == 1)
        #expect(h.scheduled.isEmpty)
    }

    @Test func theCapStillBoundsTheUnknownCase() {
        let h = Harness()
        h.now = after.addingTimeInterval(60)
        h.facts = { _ in makeFacts(memory: .pending, settledAt: after, canSend: true) }
        h.notifier.evaluate(dir)
        #expect(h.posts.isEmpty)
        #expect(h.scheduled.map(\.0) == [after.addingTimeInterval(600)])
    }

    @Test func theAttemptCarriesTheAuthPausedValueIntoTheEvaluation() {
        let h = Harness()
        h.notifier.didAttempt(dir, authPaused: true)
        #expect(h.pausedSeen == [true])
        h.notifier.didAttempt(dir, authPaused: false)
        #expect(h.pausedSeen.first == true)
        #expect(h.notifier.authPaused == false)
    }

    // MARK: - Waking up

    @Test func reevaluatingWaitingSessionsPostsOnceTheirDeadlinePassed() {
        let h = Harness()
        h.now = after.addingTimeInterval(60)
        h.facts = { _ in makeFacts(memory: .pending, settledAt: after) }
        h.notifier.evaluate(dir)
        #expect(h.posts.isEmpty)

        // The Mac slept through the deadline; the timer has not fired yet.
        h.now = after.addingTimeInterval(700)
        h.notifier.reevaluateWaiting()

        #expect(h.posts.count == 1)
    }

    @Test func reevaluatingWithNothingWaitingReadsNothing() {
        let h = Harness()
        h.notifier.reevaluateWaiting()
        #expect(h.reads.isEmpty)
    }

    @Test func aWakeNotificationReevaluatesWaitingSessions() async throws {
        let h = Harness()
        h.now = after.addingTimeInterval(60)
        h.facts = { _ in makeFacts(memory: .pending, settledAt: after) }
        h.notifier.evaluate(dir)
        let center = NotificationCenter()
        h.notifier.startObservingWake(center: center)
        h.now = after.addingTimeInterval(700)

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<100 where h.posts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(h.posts.count == 1)
        h.notifier.stopObservingWake()
    }

    @Test func afterStoppingAWakeIsIgnored() async throws {
        let h = Harness()
        h.now = after.addingTimeInterval(60)
        h.facts = { _ in makeFacts(memory: .pending, settledAt: after) }
        h.notifier.evaluate(dir)
        let center = NotificationCenter()
        h.notifier.startObservingWake(center: center)
        h.notifier.stopObservingWake()
        h.now = after.addingTimeInterval(700)

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(h.posts.isEmpty)
    }

    // MARK: - Launch sweep skips terminal minutes failures

    @Test func theLaunchSweepDoesNotReadASessionInTerminalMinutesFailure() throws {
        let fixture = try SessionFixture()
        let failed = try fixture.session("2026.09.29-1200", transcript: false, pending: false)
        try SessionFiles.writeMarker(SessionFiles.minutesError, in: failed)
        _ = try fixture.session("2026.09.29-1000", transcript: false, pending: false)
        let h = Harness()

        h.notifier.evaluatePending(root: fixture.root)

        #expect(h.reads.map(\.lastPathComponent) == ["2026.09.29-1000"])
    }

    @Test func aMinutesErrorBeingRetriedIsStillRead() throws {
        let fixture = try SessionFixture()
        let retrying = try fixture.session("2026.09.29-1200", transcript: false, pending: true)
        try SessionFiles.writeMarker(SessionFiles.minutesError, in: retrying)
        let h = Harness()

        h.notifier.evaluatePending(root: fixture.root)

        #expect(h.reads.count == 1)
    }

    // MARK: - Cutoff

    @Test func s1ASessionStartedBeforeTheCutoffIsSilentAndNeverClaims() {
        let h = Harness()
        h.facts = { _ in makeFacts(started: before) }
        h.notifier.evaluate(dir)
        #expect(h.claims.isEmpty)
        #expect(h.posts.isEmpty)
    }

    @Test func aSessionStartedExactlyAtTheCutoffIsNotified() {
        let h = Harness()
        h.facts = { _ in makeFacts(started: cutoff) }
        h.notifier.evaluate(dir)
        #expect(h.posts.count == 1)
    }

    @Test func aSessionWithoutAStartDateIsSkipped() {
        let h = Harness()
        h.facts = { _ in makeFacts(started: nil) }
        h.notifier.evaluate(dir)
        #expect(h.claims.isEmpty)
        #expect(h.posts.isEmpty)
    }

    @Test func s3TheCutoffIsLoadedBeforeTheFirstEvaluationAndOnlyOnce() {
        let h = Harness()
        h.notifier.evaluate(dir)
        h.notifier.evaluate(URL(fileURLWithPath: "/tmp/rec/2026.09.29-1100", isDirectory: true))
        #expect(h.events.first == "cutoff")
        #expect(h.events.filter { $0 == "cutoff" }.count == 1)
        #expect(h.events.firstIndex(of: "cutoff")! < h.events.firstIndex(of: "read")!)
    }

    @Test func aLateCutoffDoesNotSilenceWhatItCameBefore() {
        let h = Harness()
        h.cutoffValue = after.addingTimeInterval(10)
        h.notifier.evaluate(dir)
        #expect(h.posts.isEmpty)
    }

    // MARK: - not settled

    @Test func aFailedSessionPostsNoReadyNotice() {
        let h = Harness()
        h.facts = { _ in makeFacts(minutes: .failed) }
        h.notifier.evaluate(dir)
        #expect(h.claims.isEmpty)
        #expect(h.posts.isEmpty)
    }

    @Test func anInProgressSessionPostsNothingAndSchedulesNothingWithoutADeadline() {
        let h = Harness()
        h.facts = { _ in makeFacts(minutes: .pending) }
        h.notifier.evaluate(dir)
        #expect(h.claims.isEmpty)
        #expect(h.posts.isEmpty)
        #expect(h.scheduled.isEmpty)
    }

    // MARK: - The summary gate is the shared predicate

    @Test func aMissingSummaryIsAwaitedOnlyWhenTheGateApplies() {
        let h = Harness()
        h.facts = { _ in makeFacts(summary: .absent) }
        h.hasKey = true
        h.notifier.evaluate(dir)
        #expect(h.posts.isEmpty)

        h.hasKey = false
        h.notifier.evaluate(dir)
        #expect(h.posts.count == 1)
        #expect(h.posts[0].body == Textos.Notificacion.reunionListaCuerpo("Kickoff", partes: ["transcripción", "minuta"]))
    }

    // MARK: - Recheck timer

    @Test func aMemoryWaitSchedulesARecheckAtTheDeadlineAndSettlesThen() {
        let h = Harness()
        let settled = after
        h.now = settled.addingTimeInterval(60)
        h.facts = { _ in makeFacts(memory: .pending, settledAt: settled) }
        h.notifier.evaluate(dir)

        #expect(h.posts.isEmpty)
        #expect(h.scheduled.map(\.0) == [settled.addingTimeInterval(600)])

        // The deadline passes without an outcome: the timer fires and settles.
        h.now = settled.addingTimeInterval(600)
        h.scheduled[0].1()
        #expect(h.posts.count == 1)
        #expect(h.posts[0].kind == .ready(memoryAction: false))
    }

    @Test func repeatedEvaluationsDoNotStackTimersForTheSameDeadline() {
        let h = Harness()
        h.now = after.addingTimeInterval(60)
        h.facts = { _ in makeFacts(memory: .pending, settledAt: after) }
        h.notifier.evaluate(dir)
        h.notifier.evaluate(dir)
        h.notifier.evaluate(dir)
        #expect(h.scheduled.count == 1)
    }

    @Test func anOutcomeBeforeTheDeadlineSettlesImmediately() {
        let h = Harness()
        h.now = after.addingTimeInterval(60)
        h.facts = { _ in makeFacts(memory: .pending, settledAt: after) }
        h.notifier.evaluate(dir)
        #expect(h.posts.isEmpty)

        h.facts = { _ in makeFacts(memory: .sent(after, bank: "meetingvox"), settledAt: after) }
        h.notifier.evaluate(dir)
        #expect(h.posts.count == 1)

        // The stale timer fires later: the claim is already taken.
        h.claim = { _ in .alreadyClaimed }
        h.scheduled[0].1()
        #expect(h.posts.count == 1)
    }

    // MARK: - Launch sweep

    private func makeRoot(_ names: [String]) throws -> (SessionFixture, URL) {
        let fixture = try SessionFixture()
        for name in names { try fixture.session(name, transcript: false, pending: false) }
        return (fixture, fixture.root)
    }

    @Test func theLaunchSweepWalksNewestFirstAndStopsMoreThanADayBeforeTheCutoff() throws {
        let (fixture, root) = try makeRoot([
            "2026.09.29-1200", "2026.09.29-1000", "2026.09.28-1000", "2026.09.27-1000", "2026.09.26-1000",
        ])
        _ = fixture
        let h = Harness()
        let day: TimeInterval = 86_400
        let started: [String: Date] = [
            "2026.09.29-1200": cutoff.addingTimeInterval(3 * 3_600),
            "2026.09.29-1000": cutoff.addingTimeInterval(3_600),
            "2026.09.28-1000": cutoff.addingTimeInterval(-day + 3_600), // older than the cutoff, within a day
            "2026.09.27-1000": cutoff.addingTimeInterval(-day - 3_600), // more than a day before: stop here
            "2026.09.26-1000": cutoff.addingTimeInterval(-2 * day),
        ]
        h.facts = { started[$0.lastPathComponent].map { makeFacts(started: $0) } ?? makeFacts(started: nil) }

        h.notifier.evaluatePending(root: root)

        #expect(h.reads.map(\.lastPathComponent) == ["2026.09.29-1200", "2026.09.29-1000", "2026.09.28-1000", "2026.09.27-1000"])
        #expect(h.posts.count == 2)
        #expect(Set(h.posts.compactMap { $0.session?.lastPathComponent }) == ["2026.09.29-1200", "2026.09.29-1000"])
    }

    @Test func theLaunchSweepSkipsSessionsWithoutAStartWithoutStopping() throws {
        let (fixture, root) = try makeRoot(["2026.09.29-1200", "2026.09.29-1000"])
        _ = fixture
        let h = Harness()
        h.facts = { $0.lastPathComponent == "2026.09.29-1200" ? makeFacts(started: nil) : makeFacts() }
        h.notifier.evaluatePending(root: root)
        #expect(h.reads.count == 2)
        #expect(h.posts.map { $0.session?.lastPathComponent } == ["2026.09.29-1000"])
    }

    @Test func theLaunchSweepLoadsTheCutoffBeforeReadingAnything() throws {
        let (fixture, root) = try makeRoot(["2026.09.29-1200"])
        _ = fixture
        let h = Harness()
        h.notifier.evaluatePending(root: root)
        #expect(h.events.first == "cutoff")
    }

    @Test func theLaunchSweepSchedulesTheMemoryDeadlineOfAWaitingSession() throws {
        let (fixture, root) = try makeRoot(["2026.09.29-1200"])
        _ = fixture
        let h = Harness()
        h.now = after.addingTimeInterval(30)
        h.facts = { _ in makeFacts(memory: .pending, settledAt: after) }
        h.notifier.evaluatePending(root: root)
        #expect(h.posts.isEmpty)
        #expect(h.scheduled.map(\.0) == [after.addingTimeInterval(600)])
    }
}
