import Foundation
import Testing

@testable import MeetingVox

/// What launch does directly and what it holds back while onboarding will
/// show. Everything held can raise a TCC, Keychain or Local Network prompt,
/// which must only follow a user click.
@Suite("StartupPlan")
struct StartupPlanTests {
    @Test func withoutOnboardingLaunchDoesEverythingImmediately() {
        let plan = StartupPlan.make(.skip)
        #expect(plan.requestMicAtLaunch)
        #expect(plan.probeHindsightAtLaunch)
        #expect(plan.refreshBanksAtLaunch)
        #expect(!plan.deferBackground)
    }

    @Test func whenOnboardingWillShowLaunchRaisesNoPromptSource() {
        for reason in [OnboardingGate.Reason.firstRun, .upgrade, .versionBump(from: 1)] {
            let plan = StartupPlan.make(.show(reason))
            #expect(!plan.requestMicAtLaunch, "\(reason)")
            #expect(!plan.probeHindsightAtLaunch, "\(reason)")
            #expect(!plan.refreshBanksAtLaunch, "\(reason)")
            #expect(plan.deferBackground, "\(reason)")
        }
    }
}

/// Runs a closure on the main actor and records what happened, in order.
@MainActor
private final class Log {
    var entries: [String] = []
    func note(_ text: String) { entries.append(text) }
}

/// A sleeper the test controls, with no real time in it: `fire()` ends the
/// sleep, `nextSleepStarted()` waits until a sleep has begun, and a cancelled
/// sleep is counted instead of firing.
private final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []
    private var _cancelled = 0
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let startedContinuation: AsyncStream<Void>.Continuation
    private var startedIterator: AsyncStream<Void>.Iterator

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        startedContinuation = started.continuation
        startedIterator = started.stream.makeAsyncIterator()
    }

    var durations: [Duration] { lock.withLock { _durations } }
    var cancelledCount: Int { lock.withLock { _cancelled } }

    func fire() { continuation.yield() }

    /// Suspends until the next `sleep` call has recorded its duration.
    func nextSleepStarted() async {
        var iterator = lock.withLock { startedIterator }
        _ = await iterator.next()
        lock.withLock { startedIterator = iterator }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            lock.withLock { _durations.append(duration) }
            startedContinuation.yield()
            var iterator = stream.makeAsyncIterator()
            let fired: Void? = await iterator.next()
            if fired == nil || Task.isCancelled {
                lock.withLock { _cancelled += 1 }
                throw CancellationError()
            }
        }
    }
}

@MainActor
@Suite("DeferredStarts")
struct DeferredStartsTests {
    // MARK: Immediate vs queued

    @Test func notDeferringRunsEachActionAtOnce() {
        let log = Log()
        let starts = DeferredStarts(deferring: false)
        starts.perform(.hindsightScheduler) { log.note("scheduler") }
        starts.perform(.hindsightRequest("/a")) { log.note("request a") }
        #expect(log.entries == ["scheduler", "request a"])
        #expect(!starts.isHolding)
    }

    @Test func deferringQueuesWithoutRunning() {
        let log = Log()
        let starts = DeferredStarts(deferring: true, sleep: ManualSleeper().sleep)
        starts.perform(.micPermission) { log.note("mic") }
        starts.perform(.hindsightScheduler) { log.note("scheduler") }
        #expect(log.entries.isEmpty)
        #expect(starts.isHolding)
        #expect(starts.pendingCount == 2)
    }

    // MARK: Release

    @Test func releaseRunsTheQueueInInsertionOrderOnce() {
        let log = Log()
        let starts = DeferredStarts(deferring: true, sleep: ManualSleeper().sleep)
        starts.perform(.micPermission) { log.note("mic") }
        starts.perform(.hindsightProbe) { log.note("probe") }
        starts.perform(.banksRefresh) { log.note("banks") }
        starts.perform(.hindsightScheduler) { log.note("scheduler") }
        starts.perform(.settlementPending) { log.note("pending") }
        starts.release(.windowClosed)
        #expect(log.entries == ["mic", "probe", "banks", "scheduler", "pending"])
        #expect(!starts.isHolding)
        #expect(starts.pendingCount == 0)
    }

    @Test func aSecondReleaseDoesNothingAndKeepsTheFirstReason() {
        let log = Log()
        let starts = DeferredStarts(deferring: true, sleep: ManualSleeper().sleep)
        starts.perform(.micPermission) { log.note("mic") }
        starts.release(.windowClosed)
        starts.release(.firstRecording)
        starts.release(.timeout)
        #expect(log.entries == ["mic"])
        #expect(starts.releasedBecause == .windowClosed)
    }

    @Test func everyReleaseTriggerReleasesAndIsRecorded() {
        let triggers: [(DeferredStarts.Reason, (DeferredStarts) -> Void)] = [
            (.windowClosed, { $0.windowClosed() }),
            (.windowFailed, { $0.windowFailed() }),
            (.firstRecording, { $0.recordingStarted() }),
        ]
        for (reason, trigger) in triggers {
            let log = Log()
            let starts = DeferredStarts(deferring: true, sleep: ManualSleeper().sleep)
            #expect(starts.releasedBecause == nil)
            starts.perform(.micPermission) { log.note("mic") }
            trigger(starts)
            #expect(log.entries == ["mic"], "\(reason)")
            #expect(starts.releasedBecause == reason)
        }
    }

    @Test func afterReleaseNewActionsRunImmediately() {
        let log = Log()
        let starts = DeferredStarts(deferring: true, sleep: ManualSleeper().sleep)
        starts.release(.windowFailed)
        starts.perform(.hindsightRequest("/late")) { log.note("late") }
        #expect(log.entries == ["late"])
    }

    @Test func anActionPerformedDuringReplayRunsAfterTheRemainingQueue() {
        let log = Log()
        let starts = DeferredStarts(deferring: true, sleep: ManualSleeper().sleep)
        starts.perform(.micPermission) {
            log.note("mic")
            starts.perform(.hindsightRequest("/nested")) { log.note("nested") }
        }
        starts.perform(.hindsightScheduler) { log.note("scheduler") }
        starts.perform(.settlementPending) { log.note("pending") }
        starts.release(.windowClosed)
        #expect(log.entries == ["mic", "scheduler", "pending", "nested"])
        #expect(starts.pendingCount == 0)
    }

    @Test func anActionPerformedDuringReplayForAKeyStillQueuedReplacesIt() {
        let log = Log()
        let starts = DeferredStarts(deferring: true, sleep: ManualSleeper().sleep)
        starts.perform(.micPermission) {
            log.note("mic")
            starts.perform(.hindsightScheduler) { log.note("scheduler again") }
        }
        starts.perform(.hindsightScheduler) { log.note("scheduler") }
        starts.release(.windowClosed)
        #expect(log.entries == ["mic", "scheduler again"])
    }

    @Test func notDeferringNeverRecordsAReleaseReason() {
        let starts = DeferredStarts(deferring: false)
        starts.release(.windowClosed)
        #expect(starts.releasedBecause == nil)
    }

    // MARK: Replay of event-driven requests

    @Test func repeatedRequestsForTheSameKeyReplayOnceWithTheLatestAction() {
        let log = Log()
        let starts = DeferredStarts(deferring: true, sleep: ManualSleeper().sleep)
        starts.perform(.hindsightRequest("/a")) { log.note("a1") }
        starts.perform(.settlementEvaluate("/a")) { log.note("eval a") }
        starts.perform(.hindsightRequest("/a")) { log.note("a2") }
        starts.release(.windowClosed)
        #expect(log.entries == ["a2", "eval a"])
    }

    @Test func requestsForDifferentSessionsAllReplay() {
        let log = Log()
        let starts = DeferredStarts(deferring: true, sleep: ManualSleeper().sleep)
        starts.perform(.hindsightRequest("/a")) { log.note("req a") }
        starts.perform(.hindsightRequest("/b")) { log.note("req b") }
        starts.perform(.settlementEvaluate("/a")) { log.note("eval a") }
        starts.perform(.settlementEvaluate("/b")) { log.note("eval b") }
        starts.release(.firstRecording)
        #expect(log.entries == ["req a", "req b", "eval a", "eval b"])
    }

    @Test func requestAndEvaluateKeysForTheSamePathAreDistinct() {
        #expect(DeferredStarts.Key.hindsightRequest("/a") != .settlementEvaluate("/a"))
        #expect(DeferredStarts.Key.hindsightRequest("/a") == .hindsightRequest("/a"))
        #expect(DeferredStarts.Key.hindsightRequest("/a") != .hindsightRequest("/b"))
    }

    // MARK: Safety timeout

    @Test func theSafetyTimeoutIsThirtyMinutes() {
        #expect(DeferredStarts.safetyTimeout == .seconds(30 * 60))
    }

    @Test func deferringArmsTheTimeoutWithTheSafetyDuration() async {
        let sleeper = ManualSleeper()
        let starts = DeferredStarts(deferring: true, sleep: sleeper.sleep)
        await sleeper.nextSleepStarted()
        #expect(sleeper.durations == [DeferredStarts.safetyTimeout])
        #expect(starts.isHolding)
    }

    @Test func aCustomTimeoutIsPassedToTheSleeper() async {
        let sleeper = ManualSleeper()
        let starts = DeferredStarts(deferring: true, timeout: .seconds(5), sleep: sleeper.sleep)
        await sleeper.nextSleepStarted()
        #expect(sleeper.durations == [.seconds(5)])
        #expect(starts.isHolding)
    }

    @Test func theTimeoutReleasesTheQueue() async {
        let log = Log()
        let sleeper = ManualSleeper()
        let starts = DeferredStarts(deferring: true, sleep: sleeper.sleep)
        starts.perform(.hindsightScheduler) { log.note("scheduler") }
        await sleeper.nextSleepStarted()
        #expect(log.entries.isEmpty)
        let timeout = starts.timeoutTask
        sleeper.fire()
        await timeout?.value
        #expect(log.entries == ["scheduler"])
        #expect(starts.releasedBecause == .timeout)
        #expect(!starts.isHolding)
    }

    @Test func releasingCancelsThePendingTimeout() async {
        let sleeper = ManualSleeper()
        let starts = DeferredStarts(deferring: true, sleep: sleeper.sleep)
        await sleeper.nextSleepStarted()
        let timeout = starts.timeoutTask
        starts.release(.windowClosed)
        await timeout?.value
        #expect(sleeper.cancelledCount == 1)
        #expect(starts.releasedBecause == .windowClosed)
        #expect(starts.timeoutTask == nil)
    }

    @Test func notDeferringNeverArmsATimeout() {
        let sleeper = ManualSleeper()
        let starts = DeferredStarts(deferring: false, sleep: sleeper.sleep)
        #expect(starts.timeoutTask == nil)
        #expect(sleeper.durations.isEmpty)
    }

    @Test func aTimeoutFiringAfterAnEarlierReleaseChangesNothing() async {
        let log = Log()
        let sleeper = ManualSleeper()
        let starts = DeferredStarts(deferring: true, sleep: sleeper.sleep)
        starts.perform(.micPermission) { log.note("mic") }
        await sleeper.nextSleepStarted()
        let timeout = starts.timeoutTask
        starts.release(.firstRecording)
        await timeout?.value
        sleeper.fire()
        starts.perform(.hindsightScheduler) { log.note("scheduler") }
        #expect(log.entries == ["mic", "scheduler"])
        #expect(starts.releasedBecause == .firstRecording)
    }
}

// MARK: - Routing launch starts through the plan

/// The launch wiring, decided over seams: every automatic start goes through
/// `StartupPlan.launch`, so a plan that shows onboarding holds it and a plan
/// that skips it runs it at once.
@MainActor
@Suite("StartupPlan.launch")
struct StartupPlanLaunchTests {
    private final class Ran { var names: [String] = [] }

    private func deferred(for decision: OnboardingGate.Decision) -> DeferredStarts {
        DeferredStarts(
            deferring: StartupPlan.make(decision).deferBackground,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
    }

    private func launchEverything(_ plan: StartupPlan, _ deferred: DeferredStarts, _ ran: Ran) {
        plan.launch(.mic, key: .micPermission, through: deferred) { ran.names.append("mic") }
        plan.launch(.hindsightProbe, key: .hindsightProbe, through: deferred) { ran.names.append("probe") }
        plan.launch(.banksRefresh, key: .banksRefresh, through: deferred) { ran.names.append("banks") }
        plan.launch(.background, key: .hindsightScheduler, through: deferred) { ran.names.append("scheduler") }
        plan.launch(.background, key: .settlementPending, through: deferred) { ran.names.append("pending") }
    }

    @Test func withoutOnboardingEveryStartRunsAtOnceAndNothingIsHeld() {
        let decision = OnboardingGate.Decision.skip
        let deferred = deferred(for: decision)
        let ran = Ran()

        launchEverything(StartupPlan.make(decision), deferred, ran)

        #expect(ran.names == ["mic", "probe", "banks", "scheduler", "pending"])
        #expect(deferred.pendingCount == 0)
    }

    @Test func withOnboardingNothingRunsAtLaunchAndEverythingIsHeldInOrder() {
        let decision = OnboardingGate.Decision.show(.firstRun)
        let deferred = deferred(for: decision)
        let ran = Ran()

        launchEverything(StartupPlan.make(decision), deferred, ran)

        #expect(ran.names.isEmpty)  // no mic prompt, no probe, no LAN, no notices
        #expect(deferred.pendingCount == 5)

        deferred.windowClosed()

        #expect(ran.names == ["mic", "probe", "banks", "scheduler", "pending"])
        #expect(deferred.pendingCount == 0)
    }

    @Test func aWindowThatFailsToShowReleasesTheStartsOnce() {
        let decision = OnboardingGate.Decision.show(.upgrade)
        let deferred = deferred(for: decision)
        let ran = Ran()
        launchEverything(StartupPlan.make(decision), deferred, ran)

        deferred.windowFailed()
        deferred.windowClosed()  // a later close must not replay

        #expect(ran.names.count == 5)
        #expect(deferred.releasedBecause == .windowFailed)
    }

    @Test func aFirstRecordingReleasesTheStartsToo() {
        let decision = OnboardingGate.Decision.show(.versionBump(from: 1))
        let deferred = deferred(for: decision)
        let ran = Ran()
        launchEverything(StartupPlan.make(decision), deferred, ran)

        deferred.recordingStarted()

        #expect(ran.names.count == 5)
        #expect(deferred.releasedBecause == .firstRecording)
    }

    @Test func eventDrivenRequestsWhileTheWindowIsOpenCollapsePerSessionAndReplayOnRelease() {
        let deferred = deferred(for: .show(.firstRun))
        let ran = Ran()
        // What AppController does for hindsight.request / settlement.evaluate.
        for path in ["/r/a", "/r/b", "/r/a"] {
            deferred.perform(.hindsightRequest(path)) { ran.names.append("req:\(path)") }
        }
        deferred.perform(.settlementEvaluate("/r/a")) { ran.names.append("eval:/r/a") }
        #expect(ran.names.isEmpty)

        deferred.windowClosed()

        #expect(ran.names == ["req:/r/a", "req:/r/b", "eval:/r/a"])
    }

    @Test func afterTheReleaseEventDrivenRequestsRunAtOnce() {
        let deferred = deferred(for: .show(.firstRun))
        deferred.windowClosed()
        let ran = Ran()

        deferred.perform(.hindsightRequest("/r/a")) { ran.names.append("req") }

        #expect(ran.names == ["req"])
    }

    // MARK: - Pending minutes and summaries (they read the Keychain)

    private final class SafeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _names: [String] = []
        var names: [String] { lock.withLock { _names } }
        func append(_ name: String) { lock.withLock { _names.append(name) } }
    }

    private func resume(_ plan: StartupPlan, _ deferred: DeferredStarts, _ ran: SafeLog) async {
        await plan.resumeAtLaunch(
            transcription: { ran.append("transcription") },
            keychainJobs: { ran.append("minutes+summary") },
            through: deferred
        )
    }

    @Test func withOnboardingPendingMinutesAndSummariesWaitButTranscriptionResumes() async {
        let decision = OnboardingGate.Decision.show(.firstRun)
        let deferred = deferred(for: decision)
        let ran = SafeLog()

        await resume(StartupPlan.make(decision), deferred, ran)

        #expect(ran.names == ["transcription"], "no Keychain read (legacy prompt) before a click")
        #expect(deferred.pendingCount == 1)

        deferred.windowClosed()
        await pollMain { ran.names.count == 2 }

        #expect(ran.names == ["transcription", "minutes+summary"])
    }

    @Test func withoutOnboardingTheResumeRunsInOrderAndIsAwaited() async {
        let decision = OnboardingGate.Decision.skip
        let deferred = deferred(for: decision)
        let ran = SafeLog()

        await resume(StartupPlan.make(decision), deferred, ran)

        #expect(ran.names == ["transcription", "minutes+summary"])
        #expect(deferred.pendingCount == 0)
    }

    @Test func aFirstRecordingReleasesThePendingMinutesAndSummariesToo() async {
        let decision = OnboardingGate.Decision.show(.upgrade)
        let deferred = deferred(for: decision)
        let ran = SafeLog()
        await resume(StartupPlan.make(decision), deferred, ran)

        deferred.recordingStarted()
        await pollMain { ran.names.count == 2 }

        #expect(ran.names == ["transcription", "minutes+summary"])
        #expect(deferred.releasedBecause == .firstRecording)
    }

    @Test func aResumeAfterTheReleaseRunsAtOnce() async {
        let decision = OnboardingGate.Decision.show(.firstRun)
        let deferred = deferred(for: decision)
        deferred.windowClosed()
        let ran = SafeLog()

        await resume(StartupPlan.make(decision), deferred, ran)
        await pollMain { ran.names.count == 2 }

        #expect(ran.names == ["transcription", "minutes+summary"])
    }

    private func pollMain(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: - Automatic handoff after a transcription (minutes / summary)

    private func handoff(_ deferred: DeferredStarts, _ path: String, _ ran: SafeLog) async {
        await deferred.handoff(URL(fileURLWithPath: path)) { ran.append("handoff:\(path)") }
    }

    @Test func whileOnboardingHoldsTheHandoffWaitsAndRunsOnRelease() async {
        let deferred = deferred(for: .show(.firstRun))
        let ran = SafeLog()

        await handoff(deferred, "/r/a", ran)

        #expect(ran.names.isEmpty, "the Keychain must not be read before a click")
        #expect(deferred.pendingCount == 1)

        deferred.windowClosed()
        await pollMain { ran.names.count == 1 }

        #expect(ran.names == ["handoff:/r/a"])
    }

    @Test func eachSessionHasItsOwnHandoffAndARepeatedOneReplaysOnce() async {
        let deferred = deferred(for: .show(.upgrade))
        let ran = SafeLog()

        await handoff(deferred, "/r/a", ran)
        await handoff(deferred, "/r/b", ran)
        await handoff(deferred, "/r/a", ran)
        #expect(deferred.pendingCount == 2)

        deferred.recordingStarted()
        await pollMain { ran.names.count == 2 }
        try? await Task.sleep(for: .milliseconds(30))

        #expect(ran.names == ["handoff:/r/a", "handoff:/r/b"])
    }

    @Test func withoutOnboardingTheHandoffIsAwaitedInPlace() async {
        let deferred = deferred(for: .skip)
        let ran = SafeLog()

        await handoff(deferred, "/r/a", ran)

        #expect(ran.names == ["handoff:/r/a"], "already done when the call returns")
        #expect(deferred.pendingCount == 0)
    }

    @Test func afterTheReleaseAHandoffRunsAtOnce() async {
        let deferred = deferred(for: .show(.firstRun))
        deferred.windowClosed()
        let ran = SafeLog()

        await handoff(deferred, "/r/a", ran)

        #expect(ran.names == ["handoff:/r/a"])
        #expect(deferred.pendingCount == 0)
    }

    @Test func aHandoffKeyNeverCollidesWithTheHindsightOrSettlementKeys() {
        #expect(DeferredStarts.Key.pipelineHandoff("/r/a") != .hindsightRequest("/r/a"))
        #expect(DeferredStarts.Key.pipelineHandoff("/r/a") != .settlementEvaluate("/r/a"))
    }
}

@Suite("RecordingFlag")
struct RecordingFlagTests {
    @Test func itReflectsTheLastValueSetFromAnyThread() async {
        let flag = RecordingFlag()
        #expect(!flag.value)
        flag.set(true)
        #expect(flag.value)
        await Task.detached { flag.set(false) }.value
        #expect(!flag.value)
    }
}

@Suite("ReopenRoute")
struct ReopenRouteTests {
    @Test func whileOnboardingHoldsTheStartsTheAppOpensItInsteadOfReuniones() {
        #expect(ReopenRoute.decide(startsHeld: true) == .onboarding)
    }

    @Test func otherwiseReunionesOpensAsBefore() {
        #expect(ReopenRoute.decide(startsHeld: false) == .meetings)
    }
}
