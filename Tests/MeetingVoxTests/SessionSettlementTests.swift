import Foundation
import Testing
@testable import MeetingVox

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func facts(
    transcript: Bool = true, minutes: SessionSettlement.MarkerState = .done,
    summary: SessionSettlement.MarkerState = .done, memory: HindsightStatus? = nil,
    settledAt: Date? = nil, canSend: Bool = true, attempted: Bool = false
) -> SessionSettlement.Facts {
    SessionSettlement.Facts(
        started: t0, label: "x", hasTranscript: transcript, minutes: minutes, summary: summary,
        memory: memory, contentSettledAt: settledAt, memoryCanSend: canSend, memoryAttempted: attempted
    )
}

private func derive(_ f: SessionSettlement.Facts, summaryApplies: Bool = true, now: Date = t0) -> SessionSettlement {
    SessionSettlement.derive(f, summaryApplies: summaryApplies, now: now)
}

/// Settlement is derived from on-disk markers only.
@Suite struct SessionSettlementTests {
    // MARK: - Stage order

    @Test func s1EverythingDoneSettlesWithAllThreeParts() {
        #expect(derive(facts()) == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
    }

    @Test func s2MinutesPendingIsInProgress() {
        #expect(derive(facts(minutes: .pending)) == .inProgress(.minutes, recheckAt: nil))
    }

    @Test func noTranscriptIsInProgressTranscription() {
        #expect(derive(facts(transcript: false, minutes: .absent, summary: .absent))
            == .inProgress(.transcription, recheckAt: nil))
    }

    /// A summary that failed for good does not hide the meeting: the ready
    /// notice still posts and says what failed.
    @Test func s3SummaryErrorStillSettlesNamingTheFailure() {
        #expect(derive(facts(summary: .failed))
            == .settled(ready: [.transcript, .minutes], memoryAction: false, failed: [.summary]))
    }

    @Test func aFailedSummaryWithoutMinutesStillSettles() {
        #expect(derive(facts(minutes: .absent, summary: .failed))
            == .settled(ready: [.transcript], memoryAction: false, failed: [.summary]))
    }

    @Test func minutesErrorFailsNamingTheMinutes() {
        #expect(derive(facts(minutes: .failed)) == .failed([.minutes]))
    }

    /// A permanent minutes failure is the only one that keeps the failure
    /// notice as the meeting's single notice.
    @Test func bothFailingKeepTheFailureState() {
        #expect(derive(facts(minutes: .failed, summary: .failed)) == .failed([.minutes, .summary]))
    }

    @Test func s4MinutesNeverRequestedAreNotAwaitedNorFailed() {
        #expect(derive(facts(minutes: .absent)) == .settled(ready: [.transcript, .summary], memoryAction: false))
    }

    @Test func transcriptOnlySettlesWhenNothingElseIsAwaited() {
        #expect(derive(facts(minutes: .absent, summary: .absent), summaryApplies: false)
            == .settled(ready: [.transcript], memoryAction: false))
    }

    // MARK: - Summary applicability

    @Test func aMissingSummaryThatAppliesIsAwaited() {
        #expect(derive(facts(summary: .absent), summaryApplies: true) == .inProgress(.summary, recheckAt: nil))
    }

    @Test func aMissingSummaryThatDoesNotApplyIsNotAwaited() {
        #expect(derive(facts(summary: .absent), summaryApplies: false)
            == .settled(ready: [.transcript, .minutes], memoryAction: false))
    }

    @Test func aPendingSummaryIsAwaitedEvenIfTheGateNowSaysNo() {
        #expect(derive(facts(summary: .pending), summaryApplies: false) == .inProgress(.summary, recheckAt: nil))
    }

    // MARK: - Exhausted retries, failed -> retry -> settled

    @Test func exhaustedRetriesKeepThePendingMarkerAndTheStateInProgress() {
        // `minuta.pendiente` stays on disk after the transient retries run out.
        #expect(derive(facts(minutes: .pending)) == .inProgress(.minutes, recheckAt: nil))
        #expect(derive(facts(summary: .pending)) == .inProgress(.summary, recheckAt: nil))
    }

    @Test func aLaterSuccessAfterExhaustedRetriesSettles() {
        #expect(derive(facts(minutes: .pending)) == .inProgress(.minutes, recheckAt: nil))
        #expect(derive(facts(minutes: .done)) == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
    }

    @Test func failedThenRetriedThenSettled() {
        #expect(derive(facts(minutes: .failed)) == .failed([.minutes]))
        // "Reintentar minuta" moves minuta.error back to minuta.pendiente.
        #expect(derive(facts(minutes: .pending)) == .inProgress(.minutes, recheckAt: nil))
        #expect(derive(facts(minutes: .done)) == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
    }

    // MARK: - Ordering

    @Test func pendingMinutesWinOverAFailedSummary() {
        #expect(derive(facts(minutes: .pending, summary: .failed)) == .inProgress(.minutes, recheckAt: nil))
    }

    @Test func aMinutesFailureWinsOverAPendingMemory() {
        let f = facts(minutes: .failed, memory: .pending, settledAt: t0)
        #expect(derive(f, now: t0.addingTimeInterval(10)) == .failed([.minutes]))
    }

    @Test func aFailedSummaryStillWaitsForAPendingMemory() {
        let f = facts(summary: .failed, memory: .pending, settledAt: t0)
        #expect(derive(f, now: t0.addingTimeInterval(10)) == .inProgress(.memory, recheckAt: t0.addingTimeInterval(600)))
    }

    // MARK: - Hindsight wait

    @Test func memoryWaitIsTenMinutes() {
        #expect(SessionSettlement.memoryWait == 600)
    }

    @Test func s1AContentSettledSessionWaitsForItsFirstSendOutcome() {
        let f = facts(memory: .pending, settledAt: t0)
        #expect(derive(f, now: t0.addingTimeInterval(100))
            == .inProgress(.memory, recheckAt: t0.addingTimeInterval(600)))
    }

    @Test func s1BOnceTheOutcomeArrivesTheSessionSettles() {
        let sent = HindsightStatus.sent(t0, bank: "meetingvox")
        #expect(derive(facts(memory: sent, settledAt: t0), now: t0.addingTimeInterval(100))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
        // A rejected send is terminal-settled: ready still posts and names it.
        #expect(derive(facts(memory: .error, settledAt: t0), now: t0.addingTimeInterval(100))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false, failed: [.memory]))
    }

    @Test func s2NoOutcomeAfterTenMinutesSettlesWithoutMemory() {
        let f = facts(memory: .pending, settledAt: t0)
        #expect(derive(f, now: t0.addingTimeInterval(599)) == .inProgress(.memory, recheckAt: t0.addingTimeInterval(600)))
        #expect(derive(f, now: t0.addingTimeInterval(600))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
        #expect(derive(f, now: t0.addingTimeInterval(9_000))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
    }

    @Test func s3OmittedOrIntegrationOffNeverWaits() {
        #expect(derive(facts(memory: .omitted, settledAt: t0), now: t0)
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
        #expect(derive(facts(memory: nil, settledAt: t0), now: t0)
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
    }

    @Test func aPausedTokenShowsAsErrorAndNeverWaits() {
        // `HindsightStatus.derive` maps "pending while paused" to `.error`.
        #expect(derive(facts(memory: .error, settledAt: t0), now: t0)
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false, failed: [.memory]))
    }

    @Test func aSummaryFailureAndARejectedMemoryAreBothNamed() {
        #expect(derive(facts(summary: .failed, memory: .error, settledAt: t0), now: t0)
            == .settled(ready: [.transcript, .minutes], memoryAction: false, failed: [.summary, .memory]))
    }

    // MARK: - The memory wait only holds while a send can happen

    @Test func withNothingToSendWithNoWaitHappens() {
        // No token / base_url / bank: the coordinator would return early, so
        // no outcome will ever arrive.
        let f = facts(memory: .pending, settledAt: t0, canSend: false)
        #expect(derive(f, now: t0.addingTimeInterval(1))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
    }

    @Test func anAttemptedSessionCountsAsSettledEvenIfStillPending() {
        // A transient failure leaves the status pending; the first outcome
        // is all the notification waits for.
        let f = facts(memory: .pending, settledAt: t0, attempted: true)
        #expect(derive(f, now: t0.addingTimeInterval(1))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
    }

    @Test func aSendableUnattemptedSessionStillWaitsUpToTheCap() {
        let f = facts(memory: .pending, settledAt: t0, canSend: true, attempted: false)
        #expect(derive(f, now: t0.addingTimeInterval(1)) == .inProgress(.memory, recheckAt: t0.addingTimeInterval(600)))
        #expect(derive(f, now: t0.addingTimeInterval(600))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
    }

    @Test func aPendingMemoryWithoutAContentDateDoesNotWait() {
        #expect(derive(facts(memory: .pending, settledAt: nil))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
    }

    @Test func aMemoryWaitAlsoHoldsBackWhenSummaryIsTheLastContent() {
        // Content is settled only once minutes/summary are: pending minutes
        // are reported before any memory wait.
        #expect(derive(facts(minutes: .pending, memory: .pending, settledAt: t0), now: t0)
            == .inProgress(.minutes, recheckAt: nil))
    }

    // MARK: - Memory action

    @Test func aSessionNotYetInMemoryOffersTheMemoryAction() {
        #expect(derive(facts(memory: .notSent, settledAt: t0))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: true))
        #expect(derive(facts(memory: .short, settledAt: t0))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: true))
    }

    @Test func aSessionAlreadyInMemoryOrOmittedDoesNotOfferIt() {
        #expect(derive(facts(memory: .sent(t0, bank: nil), settledAt: t0))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
        #expect(derive(facts(memory: .omitted, settledAt: t0))
            == .settled(ready: [.transcript, .minutes, .summary], memoryAction: false))
    }
}

/// `Facts.read`: the only impure part, reading markers from a session folder.
@Suite struct SessionSettlementFactsTests {
    private func session(_ name: String = "2026.09.29-1030", files: [String] = []) throws -> (SessionFixture, URL) {
        let fixture = try SessionFixture()
        let dir = try fixture.session(name, transcript: false, pending: false)
        for file in files { try Data("{}".utf8).write(to: dir.appendingPathComponent(file)) }
        return (fixture, dir)
    }

    private func config(hindsight: Bool = false) -> ConfigValues {
        ConfigValues(raw: ["hindsight": ["enabled": hindsight, "auto_send": false, "bank": "meetingvox"]])
    }

    @Test func outputsMapToDone() throws {
        let (fixture, dir) = try session(files: ["transcript.json", "minuta.md", "resumen.json"])
        _ = fixture
        let f = SessionSettlement.Facts.read(dir, authPaused: false, config: config())
        #expect(f.hasTranscript)
        #expect(f.minutes == .done)
        #expect(f.summary == .done)
        #expect(f.memory == nil)
    }

    @Test func pendingMarkersMapToPendingEvenNextToAnOutput() throws {
        let (fixture, dir) = try session(files: ["transcript.json", "minuta.pendiente", "resumen.json", "resumen.pendiente"])
        _ = fixture
        let f = SessionSettlement.Facts.read(dir, authPaused: false, config: config())
        #expect(f.minutes == .pending)
        #expect(f.summary == .pending)
    }

    @Test func errorsWithoutTheOutputMapToFailedButNotWithIt() throws {
        let (fixture, dir) = try session(files: ["transcript.json", "minuta.error", "resumen.error", "resumen.json"])
        _ = fixture
        let f = SessionSettlement.Facts.read(dir, authPaused: false, config: config())
        #expect(f.minutes == .failed)
        #expect(f.summary == .done)
    }

    @Test func nothingOnDiskIsAbsentAndHasNoTranscript() throws {
        let (fixture, dir) = try session()
        _ = fixture
        let f = SessionSettlement.Facts.read(dir, authPaused: false, config: config())
        #expect(!f.hasTranscript)
        #expect(f.minutes == .absent)
        #expect(f.summary == .absent)
        #expect(f.contentSettledAt == nil)
    }

    @Test func startedAndLabelComeFromTheSession() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", transcript: false, pending: false)
        let f = SessionSettlement.Facts.read(dir, authPaused: false, config: config())
        #expect(f.started == ISO8601DateFormatter().date(from: "2026-09-23T14:05:00Z"))
        #expect(!f.label.isEmpty)
    }

    @Test func theReadyNoticeLabelUsesTheCalendarTitleFirst() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", transcript: false, pending: false)
        let before = SessionSettlement.Facts.read(dir, authPaused: false, config: config())
        #expect(!before.label.contains("Weekly Roadmap"))
        let event = CalendarEventRecord(
            snapshot: CalendarFixtures.snapshot(title: "Weekly Roadmap"), matchedAt: CalendarFixtures.at(1))
        try SessionFiles.setCalendarEvent(event, in: dir)
        let after = SessionSettlement.Facts.read(dir, authPaused: false, config: config())
        #expect(after.label == "Weekly Roadmap")
    }

    @Test func contentSettledAtIsTheNewestContentFile() throws {
        let (fixture, dir) = try session(files: ["transcript.json", "minuta.md", "resumen.json"])
        _ = fixture
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_005_000)
        for (name, date) in [("transcript.json", older), ("minuta.md", newest), ("resumen.json", older)] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        let f = SessionSettlement.Facts.read(dir, authPaused: false, config: config())
        #expect(f.contentSettledAt == newest)
    }

    private func hindsight(baseURL: String? = "http://hindsight.test:8888", bank: String? = "meetingvox") -> ConfigValues {
        var section: [String: Any] = ["enabled": true, "auto_send": false]
        if let baseURL { section["base_url"] = baseURL }
        if let bank { section["bank"] = bank }
        return ConfigValues(raw: ["hindsight": section])
    }

    /// A requested session is subscribed, so its status is `.pending`.
    private func requested() throws -> (SessionFixture, URL) {
        try session(files: ["transcript.json", "hindsight.solicitado"])
    }

    @Test func aPendingMemoryIsSendableWithTokenBaseURLAndBank() throws {
        let (fixture, dir) = try requested()
        _ = fixture
        let f = SessionSettlement.Facts.read(dir, authPaused: false, config: hindsight(), hasHindsightToken: { true })
        #expect(f.memory == .pending)
        #expect(f.memoryCanSend)
    }

    @Test func noTokenMeansNothingCanBeSent() throws {
        let (fixture, dir) = try requested()
        _ = fixture
        let f = SessionSettlement.Facts.read(dir, authPaused: false, config: hindsight(), hasHindsightToken: { false })
        #expect(f.memory == .pending)
        #expect(!f.memoryCanSend)
    }

    @Test func noBaseURLOrNoBankMeansNothingCanBeSent() throws {
        let (fixture, dir) = try requested()
        _ = fixture
        let noURL = SessionSettlement.Facts.read(dir, authPaused: false, config: hindsight(baseURL: nil), hasHindsightToken: { true })
        #expect(noURL.memory == .pending)
        #expect(!noURL.memoryCanSend)
        let noBank = SessionSettlement.Facts.read(dir, authPaused: false, config: hindsight(bank: nil), hasHindsightToken: { true })
        #expect(noBank.memory == .pending)
        #expect(!noBank.memoryCanSend)
    }

    @Test func aBankRecordedInTheRequestIsResolvableWithoutADefault() throws {
        let (fixture, dir) = try session(files: ["transcript.json"])
        _ = fixture
        try Data(#"{"force": false, "bank": "archivo"}"#.utf8).write(to: dir.appendingPathComponent("hindsight.solicitado"))
        let f = SessionSettlement.Facts.read(dir, authPaused: false, config: hindsight(bank: nil), hasHindsightToken: { true })
        #expect(f.memoryCanSend)
    }

    @Test func theTokenIsOnlyLookedUpForAPendingMemory() throws {
        let (fixture, dir) = try session(files: ["transcript.json"])
        _ = fixture
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        // Integration off: nothing is pending, so the Keychain is not touched.
        _ = SessionSettlement.Facts.read(dir, authPaused: false, config: config(hindsight: false), hasHindsightToken: { counter.n += 1; return true })
        #expect(counter.n == 0)
    }

    @Test func theMemoryStatusIsReadOnlyWhenTheIntegrationIsOn() throws {
        let (fixture, dir) = try session(files: ["transcript.json"])
        _ = fixture
        #expect(SessionSettlement.Facts.read(dir, authPaused: false, config: config(hindsight: false)).memory == nil)
        // Not requested, not auto-send, zero words: a sendable-but-short session.
        #expect(SessionSettlement.Facts.read(dir, authPaused: false, config: config(hindsight: true)).memory == .short)
    }
}
