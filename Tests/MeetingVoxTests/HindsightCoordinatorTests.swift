import Foundation
import Testing
@testable import MeetingVox

// MARK: - Fakes

/// Records every retain call and answers from a script (`.success` once the
/// script runs out). `holdFirst` suspends the first call until `release()`.
private final class FakeHindsight: HindsightBackend, @unchecked Sendable {
    struct Call: Sendable {
        let baseURL: URL
        let bank: String
        let token: String
        let body: Data
    }

    private let lock = NSLock()
    private var script: [HindsightOutcome]
    private var holdFirst: Bool
    private var _calls: [Call] = []
    private var deleteScript: [HindsightDeleteOutcome] = []
    private var _deleteCalls: [DeleteCall] = []
    private var gate: CheckedContinuation<Void, Never>?

    struct DeleteCall: Sendable, Equatable {
        let bank: String
        let documentID: String
        let token: String
    }

    var deleteCalls: [DeleteCall] { lock.withLock { _deleteCalls } }

    /// Answers for `deleteDocument` (`.deleted` once the script runs out).
    func scriptDeletes(_ outcomes: [HindsightDeleteOutcome]) { lock.withLock { deleteScript = outcomes } }

    func deleteDocument(baseURL: URL, bank: String, documentID: String, token: String) async -> HindsightDeleteOutcome {
        lock.withLock {
            _deleteCalls.append(DeleteCall(bank: bank, documentID: documentID, token: token))
            return deleteScript.isEmpty ? .deleted : deleteScript.removeFirst()
        }
    }

    init(script: [HindsightOutcome] = [], holdFirst: Bool = false) {
        self.script = script
        self.holdFirst = holdFirst
    }

    var calls: [Call] { lock.withLock { _calls } }
    var isHolding: Bool { lock.withLock { gate != nil } }

    func retain(baseURL: URL, bank: String, token: String, body: Data) async -> HindsightOutcome {
        let (outcome, hold): (HindsightOutcome, Bool) = lock.withLock {
            _calls.append(Call(baseURL: baseURL, bank: bank, token: token, body: body))
            let hold = holdFirst
            holdFirst = false
            return (script.isEmpty ? .success : script.removeFirst(), hold)
        }
        if hold {
            await withCheckedContinuation { continuation in lock.withLock { gate = continuation } }
        }
        return outcome
    }

    func release() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }

    func testConnection(baseURL: URL, token: String) async -> HindsightOutcome { .success }

    func listBanks(baseURL: URL, token: String) async -> [String]? { nil }
}

private struct FakeToken: APIKeyStore {
    var token: String? = "s3cret-token"
    func hasAPIKey() -> Bool { token != nil }
    func read() throws -> String? { token }
    func save(_ secret: String) throws {}
    func delete() throws {}
}

/// Like `FakeToken`, but the token can be replaced mid-test (a class, so the
/// coordinator's `Environment` closures see the update).
private final class MutableToken: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _token: String?

    init(_ token: String) { _token = token }

    var current: String? {
        get { lock.withLock { _token } }
        set { lock.withLock { _token = newValue } }
    }

    func hasAPIKey() -> Bool { current != nil }
    func read() throws -> String? { current }
    func save(_ secret: String) throws { current = secret }
    func delete() throws { current = nil }
}

private final class HindsightProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    private var _statuses: [HindsightCoordinator.Status] = []
    private var _notifications: [String] = []
    private var _auth: [Bool] = []
    private var _notices: [Notice] = []
    private var _attempts: [URL] = []
    private var _attemptPaused: [Bool] = []

    var notices: [Notice] { lock.withLock { _notices } }
    /// Sessions `didAttempt` fired for, in order.
    var attempts: [URL] { lock.withLock { _attempts } }
    /// The `authPaused` value each `didAttempt` carried.
    var attemptPaused: [Bool] { lock.withLock { _attemptPaused } }
    var now: Date { lock.withLock { _now } }
    var idleCount: Int { lock.withLock { _statuses.filter { $0 == .idle }.count } }
    var notifications: [String] { lock.withLock { _notifications } }
    var auth: [Bool] { lock.withLock { _auth } }

    func status(_ s: HindsightCoordinator.Status) { lock.withLock { _statuses.append(s) } }
    func notify(_ notice: Notice) {
        lock.withLock {
            _notifications.append(notice.title)
            _notices.append(notice)
        }
    }
    func attempted(_ dir: URL, authPaused: Bool) {
        lock.withLock {
            _attempts.append(dir)
            _attemptPaused.append(authPaused)
        }
    }
    func authChanged(_ paused: Bool) { lock.withLock { _auth.append(paused) } }
    /// Moves the coordinator's injected clock forward, independent of any
    /// file's modification date.
    func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
}

/// Thread-safe counter for `HindsightCoordinator.setChangeHandler` calls.
private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}

/// A config default bank that can change mid-test (a class, so the
/// coordinator's `Environment.config` closure sees the update) — for
/// proving a bank-less record is frozen before a later default change.
private final class BankBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _current: String?
    init(_ bank: String?) { _current = bank }
    var current: String? {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }
}

private let mexico = TimeZone(identifier: "America/Mexico_City")!

private func makeCoordinator(
    _ backend: FakeHindsight, _ probe: HindsightProbe,
    enabled: Bool = true, autoSend: Bool = true, since: String = "2026-09-01", token: String? = "s3cret-token",
    minWords: Int = 0, minMinutes: Int = 0, keyStore: (any APIKeyStore)? = nil,
    /// Overrides the fixed `"meetingvox"` default bank with a live value — for
    /// tests that change the config default mid-test (`nil` box entry omits
    /// the key entirely, i.e. no default bank configured).
    bankBox: BankBox? = nil
) async -> HindsightCoordinator {
    let env = HindsightCoordinator.Environment(
        backend: backend,
        keyStore: keyStore ?? FakeToken(token: token),
        config: {
            var hindsight: [String: Any] = [
                "enabled": enabled, "auto_send": autoSend, "base_url": "http://hindsight.test:8888",
                "owner_name": "Usuario", "owner_description": "quien grabó la reunión", "since": since,
                "min_words": minWords, "min_minutes": minMinutes,
            ]
            let bank: String? = bankBox != nil ? bankBox!.current : "meetingvox"
            if let bank { hindsight["bank"] = bank }
            return ConfigValues(raw: ["hindsight": hindsight])
        },
        now: { probe.now },
        notify: { probe.notify($0) },
        timeZone: mexico,
        templateName: { _ in nil },
        didAttempt: { probe.attempted($0, authPaused: $1) }
    )
    let coordinator = HindsightCoordinator(environment: env)
    await coordinator.setStatusHandler { probe.status($0) }
    await coordinator.setAuthPausedHandler { probe.authChanged($0) }
    return coordinator
}

/// Run `action` and wait until the drain it starts has finished.
private func settle(_ probe: HindsightProbe, _ action: () async -> Void) async throws {
    let before = probe.idleCount
    await action()
    try await waitUntil { probe.idleCount > before }
}

private func items(_ call: FakeHindsight.Call) throws -> [[String: Any]] {
    let json = try #require(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
    return try #require(json["items"] as? [[String: Any]])
}

private func operationID(_ call: FakeHindsight.Call) throws -> String {
    let json = try #require(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
    return try #require(json["operation_id"] as? String)
}

private func writeMinutes(_ dir: URL, _ text: String = "# Minuta\n\nAcuerdos.", modified: Date? = nil) throws {
    let url = dir.appendingPathComponent(SessionFiles.minutes)
    try Data(text.utf8).write(to: url)
    if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
}

/// Replace the transcript with one `me` segment (changes the content hash).
private func rewriteTranscript(_ dir: URL, _ text: String) throws {
    let json = #"{"engine": "fake", "model": "fake", "segments": [{"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "\#(text)"}]}"#
    try Data(json.utf8).write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
}

private func setModified(_ dir: URL, _ name: String, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir.appendingPathComponent(name).path)
}

private func hindsightFiles(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("hindsight.") }.sorted()
}

private func decode<T: Decodable>(_ type: T.Type, _ dir: URL, _ name: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(contentsOf: dir.appendingPathComponent(name)))
}

// MARK: - Tests

@Suite struct HindsightCoordinatorTests {
    @Test func sendsOneTranscriptItemAndRecordsIt() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try writeMinutes(dir)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.count == 1)
        let call = try #require(backend.calls.first)
        #expect(call.baseURL == URL(string: "http://hindsight.test:8888"))
        #expect(call.bank == "meetingvox")
        #expect(call.token == "s3cret-token")
        #expect(try items(call).map { $0["document_id"] as? String } == ["mv-2026.09.23-1405"])
        let record = try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent)
        #expect(record.contentHash.count == 64)
        #expect(record.operationID == (try operationID(call)))
        #expect(record.sentAt == probe.now)
        #expect(record.documentID == "mv-2026.09.23-1405")
        #expect(hindsightFiles(dir) == ["hindsight.json", "hindsight.log"])
    }

    // MARK: - didAttempt (settlement notifier hook)

    /// After every outcome of a real send attempt the coordinator tells the
    /// settlement notifier, so it can decide "ready" without waiting for the
    /// 10-minute memory cap.
    @Test func didAttemptFiresAfterASuccessfulSend() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.count == 1)
        #expect(SessionFiles.exists(SessionFiles.hindsightSent, in: dir))
        #expect(probe.attempts == [dir])
        #expect(probe.attemptPaused == [false])
    }

    @Test func didAttemptFiresAfterATransientFailure() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.transient("offline")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }

        #expect(!SessionFiles.exists(SessionFiles.hindsightSent, in: dir))
        #expect(probe.attempts == [dir])
    }

    @Test func didAttemptFiresAfterARejection() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.rejected(status: 422, message: "field required")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }

        #expect(SessionFiles.exists(SessionFiles.hindsightError, in: dir))
        #expect(probe.attempts == [dir])
    }

    @Test func didAttemptFiresAfterAnUnauthorizedResponse() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.unauthorized(status: 401)])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }

        #expect(await coordinator.authPaused)
        #expect(probe.attempts == [dir])
        // The value travels with the callback, so the settlement notifier
        // never has to race the separate auth-paused handler.
        #expect(probe.attemptPaused == [true])
    }

    /// Nothing was attempted (minutes still pending, so not ready): no callback.
    @Test func didAttemptDoesNotFireWhenNothingWasSent() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: true)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.isEmpty)
        #expect(probe.attempts.isEmpty)
    }

    @Test func didAttemptDoesNotFireWhenTheSessionIsAlreadyInMemory() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)
        try await settle(probe) { await coordinator.request(dir) }
        #expect(probe.attempts == [dir])

        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.count == 1)
        #expect(probe.attempts == [dir])
    }

    @Test func transcriptOnlyWhenMinutesWereNeverRequested() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }

        #expect(try items(#require(backend.calls.first)).map { $0["document_id"] as? String }
            == ["mv-2026.09.23-1405"])
    }

    @Test func waitsWhileMinutesArePending() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: true)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.isEmpty)
        #expect(hindsightFiles(dir).isEmpty)
    }

    @Test func failedMinutesSendTheTranscriptAlone() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try SessionFiles.writeMarker(SessionFiles.minutesError, in: dir)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }

        #expect(try items(#require(backend.calls.first)).count == 1)
    }

    @Test func summaryInFlightHoldsMinutesUpTo30Minutes() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let probe = HindsightProbe()
        try writeMinutes(dir, modified: probe.now.addingTimeInterval(-10 * 60))
        try SessionFiles.writeMarker(SessionFiles.summaryPending, in: dir)
        let backend = FakeHindsight()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.isEmpty)

        try setModified(dir, SessionFiles.minutes, probe.now.addingTimeInterval(-31 * 60))
        try await settle(probe) { await coordinator.request(dir) }
        #expect(try items(#require(backend.calls.first)).count == 1)
    }

    @Test func summaryInFlightHoldsTranscriptOnlySessionToo() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let probe = HindsightProbe()
        try setModified(dir, SessionFiles.transcriptJSON, probe.now.addingTimeInterval(-5 * 60))
        try SessionFiles.writeMarker(SessionFiles.summaryPending, in: dir)
        let backend = FakeHindsight()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.isEmpty)

        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.summaryPending))
        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.count == 1)
    }

    /// The 30-minute summary-wait cap is a clock timeout, not a stale-file
    /// heuristic: advancing the coordinator's injected clock past it — with
    /// the content's modification date left untouched — must release a
    /// still-pending summary on its own.
    @Test func summaryWaitExpiresByClockAlone() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let probe = HindsightProbe()
        try setModified(dir, SessionFiles.transcriptJSON, probe.now)
        try SessionFiles.writeMarker(SessionFiles.summaryPending, in: dir)
        let backend = FakeHindsight()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.isEmpty, "still within the 30-minute wait")

        probe.advance(29 * 60)
        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.isEmpty, "29 minutes have not elapsed yet")

        probe.advance(2 * 60)
        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.count == 1, "31 minutes elapsed: the summary wait expired")
        #expect(try items(#require(backend.calls.first)).count == 1, "transcript-only: no minuta.md was ever written")
    }

    @Test func unchangedContentIsNotSentAgain() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.count == 1)
    }

    /// "Aplicar glosario" reapplying to a legacy
    /// transcript rewrites transcript.json (adds/refreshes `text_raw`)
    /// without changing the corrected text, so the content hash is
    /// unchanged and this stays the "already in memory" branch — but it
    /// must still catch hindsight.json's mtime up so `readCheap` (mtime
    /// based) doesn't show the session stuck on "Pendiente" forever.
    @Test func reapplyingTheGlossaryToAlreadySentContentRefreshesTheSentRecordsMtime() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.count == 1)

        // Simulate the reapply: same corrected text (unchanged hash), only
        // the file itself moves forward in time.
        let newer = probe.now.addingTimeInterval(3600)
        try setModified(dir, SessionFiles.transcriptJSON, newer)
        let sentBefore = try #require(HindsightFacts.modified(dir, SessionFiles.hindsightSent))
        #expect(sentBefore < newer)
        #expect(!HindsightFacts.readCheap(dir).isSentCurrent, "stuck on Pendiente before the fix")

        // The refresh stamps the injected clock, not the real filesystem
        // clock — advance it past `newer` so the fix is unambiguous.
        probe.advance(7200)
        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.count == 1, "still nothing sent: the content is unchanged")
        let sentAfter = try #require(HindsightFacts.modified(dir, SessionFiles.hindsightSent))
        #expect(sentAfter >= newer)
        #expect(HindsightFacts.readCheap(dir).isSentCurrent, "readCheap now agrees the session is sent/current")
    }

    /// Same shape for a rejection: the equivalent "already rejected for this
    /// content" branch must also catch hindsight.error's mtime up.
    @Test func reapplyingTheGlossaryToAlreadyRejectedContentRefreshesTheErrorRecordsMtime() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.rejected(status: 422, message: "field required")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(SessionFiles.exists(SessionFiles.hindsightError, in: dir))

        let newer = probe.now.addingTimeInterval(3600)
        try setModified(dir, SessionFiles.transcriptJSON, newer)
        let errorBefore = try #require(HindsightFacts.modified(dir, SessionFiles.hindsightError))
        #expect(errorBefore < newer)
        #expect(!HindsightFacts.readCheap(dir).failed, "looks pending, not error, before the fix")

        probe.advance(7200)
        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.count == 1, "still nothing sent: the same rejected content")
        let errorAfter = try #require(HindsightFacts.modified(dir, SessionFiles.hindsightError))
        #expect(errorAfter >= newer)
        #expect(HindsightFacts.readCheap(dir).failed, "readCheap now agrees the session is still an error")
    }

    @Test func minutesArrivingLaterDoNotResend() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        try writeMinutes(dir)
        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.count == 1)
    }

    @Test func transcriptChangeResendsWithANewOperation() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        try rewriteTranscript(dir, "Contenido nuevo")
        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.count == 2)
        #expect(try operationID(backend.calls[0]) != (try operationID(backend.calls[1])))
    }

    @Test func transientFailureWritesNothingAndTheRetryReusesTheOperation() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.transient("offline")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(!SessionFiles.exists(SessionFiles.hindsightSent, in: dir))
        #expect(!SessionFiles.exists(SessionFiles.hindsightError, in: dir))

        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.count == 2)
        #expect(backend.calls[0].body == backend.calls[1].body)
        #expect(SessionFiles.exists(SessionFiles.hindsightSent, in: dir))
    }

    /// A dead server would otherwise fill `hindsight.log` with the same
    /// "not sent: transient" line every sweep (dedup keys on the content
    /// hash, not the exact wording, so a different transient reason each
    /// time still collapses to one line) while still retrying every sweep;
    /// a later success is unaffected and logged normally.
    @Test func repeatedTransientFailuresForUnchangedContentLogOnce() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.transient("offline"), .transient("timeout")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.count == 2, "still retried on every sweep")

        let afterFailures = try String(contentsOf: dir.appendingPathComponent(SessionFiles.hindsightLog), encoding: .utf8)
        #expect(afterFailures.split(separator: "\n").filter { $0.contains("not sent:") }.count == 1)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(SessionFiles.exists(SessionFiles.hindsightSent, in: dir))
        let final = try String(contentsOf: dir.appendingPathComponent(SessionFiles.hindsightLog), encoding: .utf8)
        #expect(final.split(separator: "\n").filter { $0.contains("not sent:") }.count == 1, "no new transient line")
        #expect(final.split(separator: "\n").contains { $0.contains("sent") && !$0.contains("not sent") })
    }

    @Test func unauthorizedPausesEverySendUntilResumed() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.unauthorized(status: 401)])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(await coordinator.authPaused)
        #expect(probe.auth == [true])

        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.count == 1)

        await coordinator.resumeAuth()
        #expect(probe.auth == [true, false])
        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.count == 2)
        #expect(SessionFiles.exists(SessionFiles.hindsightSent, in: dir))
    }

    /// A send is in flight with the old token when a fresh one is saved and
    /// `resumeAuth()` is called; the in-flight call then comes back 401 for
    /// the *old* token. That stale rejection must not pause sends — it
    /// should just re-evaluate the session, which then sends with the new
    /// token.
    @Test func staleUnauthorizedAfterResumeAuthDoesNotRePauseAndReevaluates() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let keyStore = MutableToken("old-token")
        let backend = FakeHindsight(script: [.unauthorized(status: 401)], holdFirst: true)
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, keyStore: keyStore)

        await coordinator.request(dir)
        try await waitUntil { backend.isHolding }
        #expect(backend.calls.first?.token == "old-token")

        keyStore.current = "new-token"
        await coordinator.resumeAuth()
        backend.release()

        try await waitUntil { backend.calls.count == 2 }
        #expect(!(await coordinator.authPaused))
        #expect(probe.auth.isEmpty)
        #expect(backend.calls[1].token == "new-token")
        try await waitUntil { SessionFiles.exists(SessionFiles.hindsightSent, in: dir) }
    }

    @Test func rejectionIsRecordedNotifiedOnceAndRetriedOnlyForNewContent() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.rejected(status: 422, message: "field required")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        let error = try decode(HindsightErrorRecord.self, dir, SessionFiles.hindsightError)
        #expect(error.status == 422)
        #expect(error.message == "field required")
        #expect(error.hash.count == 64)
        #expect(probe.notifications == [Textos.Memoria.envioRechazado])
        // The rejection notice names what failed, no "revisa hindsight.log".
        #expect(probe.notices.map(\.kind) == [.failure(.memory, retryable: false)])
        #expect(probe.notices.first?.body == Textos.Memoria.envioRechazadoCuerpo("2026.09.23-1405"))
        #expect(probe.notices.first?.session == dir)
        #expect(probe.notices.allSatisfy { !$0.body.contains("revisa") && !$0.body.contains(".log") })

        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.count == 1)
        #expect(probe.notifications.count == 1)

        try rewriteTranscript(dir, "Contenido nuevo")
        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.count == 2)
        #expect(!SessionFiles.exists(SessionFiles.hindsightError, in: dir))
        #expect(SessionFiles.exists(SessionFiles.hindsightSent, in: dir))

        for name in hindsightFiles(dir) {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains("s3cret-token"), "token leaked into \(name)")
        }
    }

    @Test func skippedSessionIsNeverSentUntilUnskipped() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        await coordinator.setSkipped(dir, true)
        #expect(SessionFiles.exists(SessionFiles.hindsightSkip, in: dir))
        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.isEmpty)

        try await settle(probe) { await coordinator.setSkipped(dir, false) }
        #expect(!SessionFiles.exists(SessionFiles.hindsightSkip, in: dir))
        #expect(backend.calls.count == 1)
    }

    @Test func sweepLeavesIneligibleSessionsUntouched() async throws {
        let fixture = try SessionFixture()
        let before = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        // Fixture starts 2026-09-23 08:05 in Mexico: one day before the cutoff.
        let coordinator = await makeCoordinator(backend, probe, since: "2026-09-24")

        try await settle(probe) { await coordinator.sweep(root: fixture.root) }

        #expect(backend.calls.isEmpty)
        #expect(hindsightFiles(before).isEmpty)
    }

    @Test func disabledOrMissingTokenSendsNothing() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()

        let disabled = await makeCoordinator(backend, probe, enabled: false)
        try await settle(probe) { await disabled.request(dir) }
        let noToken = await makeCoordinator(backend, probe, token: nil)
        try await settle(probe) { await noToken.request(dir) }

        #expect(backend.calls.isEmpty)
        #expect(hindsightFiles(dir).isEmpty)
    }

    @Test func sweepSendsReadySessionsOldestFirst() async throws {
        let fixture = try SessionFixture()
        try fixture.session("2026.09.23-1600", pending: false)
        try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.sweep(root: fixture.root) }

        #expect(try backend.calls.map { try items($0)[0]["document_id"] as? String } == [
            "mv-2026.09.23-1405", "mv-2026.09.23-1600",
        ])
    }

    @Test func corruptTranscriptIsLoggedOnceAndDoesNotBlockOthers() async throws {
        let fixture = try SessionFixture()
        let broken = try fixture.session("2026.09.23-1405", pending: false)
        try Data("{".utf8).write(to: broken.appendingPathComponent(SessionFiles.transcriptJSON))
        let good = try fixture.session("2026.09.23-1600", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        try await settle(probe) { await coordinator.sweep(root: fixture.root) }

        #expect(backend.calls.count == 1)
        #expect(SessionFiles.exists(SessionFiles.hindsightSent, in: good))
        let log = try String(contentsOf: broken.appendingPathComponent(SessionFiles.hindsightLog), encoding: .utf8)
        #expect(log.split(separator: "\n").count == 1)
    }

    @Test func retryNowClearsARejectionAndResends() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.rejected(status: 422, message: "field required")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(SessionFiles.exists(SessionFiles.hindsightError, in: dir))

        try await settle(probe) { await coordinator.retryNow(dir) }

        #expect(!SessionFiles.exists(SessionFiles.hindsightError, in: dir))
        #expect(SessionFiles.exists(SessionFiles.hindsightSent, in: dir))
        #expect(backend.calls.count == 2)
    }

    /// In manual mode a rejection leaves the session unsubscribed (the
    /// request marker that led to it is removed on `.rejected`), so
    /// `retryNow` must resubscribe it — otherwise `run` bails out at the
    /// "not subscribed, not auto-eligible" guard and the retry does nothing.
    @Test func retryNowResubscribesAndResendsInManualMode() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.rejected(status: 422, message: "field required")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: false) }
        #expect(SessionFiles.exists(SessionFiles.hindsightError, in: dir))
        #expect(!SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))

        try await settle(probe) { await coordinator.retryNow(dir) }

        #expect(backend.calls.count == 2)
        #expect(!SessionFiles.exists(SessionFiles.hindsightError, in: dir))
        #expect(SessionFiles.exists(SessionFiles.hindsightSent, in: dir))
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).documentID == "mv-2026.09.23-1405")
    }

    @Test func retryNowLiftsAnAuthPause() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.unauthorized(status: 401)])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(await coordinator.authPaused)

        try await settle(probe) { await coordinator.retryNow(dir) }

        #expect(!(await coordinator.authPaused))
        #expect(probe.auth == [true, false])
        #expect(SessionFiles.exists(SessionFiles.hindsightSent, in: dir))
    }

    @Test func changeHandlerFiresOnSendSuccessRejectionSkipAndRetry() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)
        let changes = ChangeCounter()
        await coordinator.setChangeHandler { changes.increment() }

        try await settle(probe) { await coordinator.request(dir) }
        #expect(changes.count == 1, "one change on successful send")

        // setSkipped(true) only writes a marker: no send is queued, so
        // there's no drain to wait on.
        await coordinator.setSkipped(dir, true)
        #expect(changes.count == 2)

        try await settle(probe) { await coordinator.setSkipped(dir, false) }
        #expect(changes.count == 3)
    }

    /// A 401/403 always pauses from a real false→true transition (`run()`
    /// itself guards `!authPaused` at entry), so every rejection here is
    /// worth a refresh — sessions still waiting on minutes/summary flip
    /// from "Pendiente" to "Error al enviar" the moment the coordinator
    /// pauses, not just the one that triggered the 401.
    @Test func changeHandlerFiresWhenAuthPauses() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.unauthorized(status: 401)])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)
        let changes = ChangeCounter()
        await coordinator.setChangeHandler { changes.increment() }

        try await settle(probe) { await coordinator.request(dir) }

        #expect(await coordinator.authPaused)
        #expect(changes.count == 1)
    }

    /// The mirror case of the 401 test: lifting a pause is just as much a
    /// status change (an "Error al enviar" row may resolve on its own once
    /// the next sweep runs) and must refresh the window too.
    @Test func changeHandlerFiresWhenResumeAuthActuallyUnpauses() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.unauthorized(status: 401)])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)
        let changes = ChangeCounter()
        await coordinator.setChangeHandler { changes.increment() }

        try await settle(probe) { await coordinator.request(dir) }
        #expect(changes.count == 1, "the pause itself")

        #expect(await coordinator.resumeAuth())
        #expect(changes.count == 2, "the unpause")
    }

    /// `resumeAuth()` is called unconditionally on every config change and
    /// token save (see `HindsightScheduler`), so a no-op call — nothing was
    /// paused — must not spam a refresh on every one of those.
    @Test func resumeAuthWithNothingPausedDoesNotFireTheChangeHandler() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)
        let changes = ChangeCounter()
        await coordinator.setChangeHandler { changes.increment() }

        #expect(!(await coordinator.resumeAuth()))
        #expect(changes.count == 0)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(changes.count == 1, "unaffected: the earlier no-op resumeAuth() didn't fire")
    }

    /// `retryNow` must never double-notify for the same synchronous event:
    /// when it also lifts a pause, that transition (via `resumeAuth()`) is
    /// the one and only refresh for the marker removal + unpause pair — not
    /// a second one just because a marker was also touched. Checked right
    /// after `retryNow` returns, before the resend it queues has had a
    /// chance to run (and post its own, separate change for its own
    /// outcome).
    @Test func retryNowFiresTheChangeHandlerExactlyOnceEvenWhenItAlsoUnpauses() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.unauthorized(status: 401)])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(await coordinator.authPaused)

        let changes = ChangeCounter()
        await coordinator.setChangeHandler { changes.increment() }

        await coordinator.retryNow(dir)

        #expect(!(await coordinator.authPaused))
        #expect(changes.count == 1, "one refresh for the unpause; the queued resend hasn't completed yet")
    }

    @Test func requestDuringASendIsEvaluatedAgain() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(holdFirst: true)
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        await coordinator.request(dir)
        try await waitUntil { backend.isHolding }
        try rewriteTranscript(dir, "Contenido nuevo")
        await coordinator.request(dir)
        backend.release()
        try await waitUntil { backend.calls.count == 2 }

        #expect(try operationID(backend.calls[0]) != (try operationID(backend.calls[1])))
    }

    // MARK: - v2: manual mode, subscription, forced resend

    @Test func manualModeSendsNothingWithoutARequest() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.request(dir) }
        await coordinator.sweep(root: fixture.root)
        try await Task.sleep(for: .milliseconds(50))

        #expect(backend.calls.isEmpty)
        #expect(hindsightFiles(dir).isEmpty)
    }

    @Test func sendWritesTheRequestSendsAndClearsIt() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: false) }

        #expect(backend.calls.count == 1)
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).documentID == "mv-2026.09.23-1405")
        #expect(!SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))
    }

    @Test func manualSendIgnoresTheCutoffAndTheShortThreshold() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false, since: "2027-01-01", minWords: 150, minMinutes: 2)

        try await settle(probe) { await coordinator.send(dir, force: false) }

        #expect(backend.calls.count == 1)
    }

    @Test func sendIsIgnoredWhileTheIntegrationIsOff() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let coordinator = await makeCoordinator(FakeHindsight(), HindsightProbe(), enabled: false)

        await coordinator.send(dir, force: false)

        #expect(!SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))
    }

    @Test func sendLiftsNoEnviar() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)
        await coordinator.setSkipped(dir, true)

        try await settle(probe) { await coordinator.send(dir, force: false) }

        #expect(!SessionFiles.exists(SessionFiles.hindsightSkip, in: dir))
        #expect(backend.calls.count == 1)
    }

    @Test func aRequestNotReadyYetIsSentByALaterSweep() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: true)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: false) }
        #expect(backend.calls.isEmpty)
        #expect(SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))

        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.minutesPending))
        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        #expect(backend.calls.count == 1)
        #expect(!SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))
    }

    @Test func manualSweepOnlyTouchesSubscribedSessions() async throws {
        let fixture = try SessionFixture()
        let requested = try fixture.session("2026.09.23-1405", pending: false)
        let untouched = try fixture.session("2026.09.23-1600", pending: false)
        try HindsightFacts.writeJSON(HindsightRequestMarker(force: false, requestedAt: nil), requested, SessionFiles.hindsightRequested)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.sweep(root: fixture.root) }

        #expect(try backend.calls.map { try items($0)[0]["document_id"] as? String } == ["mv-2026.09.23-1405"])
        #expect(hindsightFiles(untouched).isEmpty)
    }

    @Test func subscribedSessionResendsWhenTheTranscriptChanges() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: false) }
        let first = try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent)
        try writeMinutes(dir, "# Minuta regenerada")
        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        #expect(backend.calls.count == 1, "regenerated minutes never resend")

        try rewriteTranscript(dir, "Re-transcripción")
        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        #expect(backend.calls.count == 2)
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).contentHash != first.contentHash)
    }

    @Test func forcedResendUsesANewOperationIDAndClearsTheMarker() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: false) }
        try await settle(probe) { await coordinator.send(dir, force: false) }
        #expect(backend.calls.count == 1, "a plain request for content already in memory sends nothing")
        #expect(!SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))

        try await settle(probe) { await coordinator.send(dir, force: true) }
        #expect(backend.calls.count == 2)
        #expect(try operationID(backend.calls[0]) != (try operationID(backend.calls[1])))
        #expect(backend.calls[0].body != backend.calls[1].body)
        #expect(!SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))
    }

    @Test func forcedResendRetriedAfterATransientFailureReusesItsOperationID() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.success, .transient("HTTP 503"), .success])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: false) }
        try await settle(probe) { await coordinator.send(dir, force: true) }
        #expect(SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))
        probe.advance(600)
        try await settle(probe) { await coordinator.sweep(root: fixture.root) }

        #expect(backend.calls.count == 3)
        #expect(try operationID(backend.calls[1]) == (try operationID(backend.calls[2])))
        #expect(!SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))
    }

    @Test func aRequestWrittenDuringASendSurvivesIt() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(holdFirst: true)
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        await coordinator.send(dir, force: false)
        try await waitUntil { backend.isHolding }
        probe.advance(5)
        await coordinator.send(dir, force: true)
        backend.release()
        try await waitUntil { backend.calls.count == 2 }
        try await waitUntil { !SessionFiles.exists(SessionFiles.hindsightRequested, in: dir) }

        #expect(try operationID(backend.calls[0]) != (try operationID(backend.calls[1])))
    }

    @Test func legacyV1SessionIsNotSubscribedAndIsReplacedOnSend() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try JSONSerialization.data(withJSONObject: [
            "hash": "d6a1", "operation_id": "d6a1268e-e9a8-5dd9-98ca-3cf774107a55", "sent_at": "2026-09-24T18:08:36Z",
            "document_ids": ["quill-2026.09.23-1405-minuta", "quill-2026.09.23-1405-transcripcion"],
        ]).write(to: dir.appendingPathComponent(SessionFiles.hindsightSent))
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        await coordinator.sweep(root: fixture.root)
        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.isEmpty)

        try await settle(probe) { await coordinator.send(dir, force: false) }
        #expect(backend.calls.count == 1)
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).documentID == "mv-2026.09.23-1405")
    }

    @Test func autoModeSkipsShortSessionsAndLogsOnce() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: true, minWords: 150, minMinutes: 2)

        try await settle(probe) { await coordinator.request(dir) }
        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.isEmpty)
        let log = try String(contentsOf: dir.appendingPathComponent(SessionFiles.hindsightLog), encoding: .utf8)
        #expect(log.components(separatedBy: "short session").count == 2)
        #expect(!SessionFiles.exists(SessionFiles.hindsightSent, in: dir))
    }

    @Test func autoModeWithoutACutoffSendsNothing() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: true, since: "")

        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.isEmpty)
    }

    // MARK: - v2 edge cases

    /// The bug this guards: with `force`, the "already rejected" short
    /// circuit was skipped (as it should be — a forced resend must reach
    /// the backend even for content it already rejected), but on
    /// `.rejected` the request marker used to survive, so every later sweep
    /// found it still subscribed and resent the same doomed content forever.
    @Test func rejectedForcedResendClearsTheMarkerAndStopsLooping() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.rejected(status: 422, message: "field required")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: true) }
        #expect(backend.calls.count == 1)
        #expect(SessionFiles.exists(SessionFiles.hindsightError, in: dir))
        #expect(!SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))
        #expect(probe.notifications == [Textos.Memoria.envioRechazado])

        // No longer subscribed: the sweep finds nothing to enqueue and
        // never drains, so there's no `.idle` to wait on (as in
        // `manualModeSendsNothingWithoutARequest`) — a short fixed wait
        // instead.
        await coordinator.sweep(root: fixture.root)
        try await Task.sleep(for: .milliseconds(50))

        #expect(backend.calls.count == 1, "no longer subscribed: nothing to resend")
        #expect(probe.notifications.count == 1)
    }

    /// A forced marker missing `requested_at` (malformed, or written before
    /// this field existed) must resolve it once and persist that value, not
    /// call the clock fresh on every run — otherwise a retried forced
    /// resend would get a new operation id each time.
    @Test func aForcedMarkerWithoutARequestedAtIsResolvedOnceAndReused() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try Data(#"{"force": true}"#.utf8).write(to: dir.appendingPathComponent(SessionFiles.hindsightRequested))
        let backend = FakeHindsight(script: [.transient("offline"), .transient("offline")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        #expect(backend.calls.count == 1)
        let resolved = try #require(HindsightFacts.readRequest(dir))
        #expect(resolved.force)
        #expect(resolved.requestedAt != nil)

        probe.advance(60)
        try await settle(probe) { await coordinator.sweep(root: fixture.root) }

        #expect(backend.calls.count == 2)
        #expect(try operationID(backend.calls[0]) == (try operationID(backend.calls[1])), "same resolved requested_at both times")
        #expect(HindsightFacts.readRequest(dir)?.requestedAt == resolved.requestedAt, "not re-resolved on the retry")
    }

    /// A plain (non-forced) request for content Hindsight already rejected
    /// must not stay pending forever — the UI's way to try again is
    /// "Reintentar envío" (which clears hindsight.error), not a request that
    /// silently resends the identical, still-doomed content every sweep.
    @Test func plainRequestMatchingAnExistingErrorClearsTheMarker() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.rejected(status: 422, message: "field required")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: false) }
        #expect(SessionFiles.exists(SessionFiles.hindsightError, in: dir))
        #expect(!SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))

        // Re-request the same (still rejected) content without going
        // through "Reintentar envío" first.
        try HindsightFacts.writeJSON(HindsightRequestMarker(force: false, requestedAt: probe.now), dir, SessionFiles.hindsightRequested)
        try await settle(probe) { await coordinator.sweep(root: fixture.root) }

        #expect(backend.calls.count == 1, "no new network call: still the same rejected content")
        #expect(!SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))
    }

    // MARK: - Banks

    @Test func sendToAChosenBankRecordsItInTheMarkerAndTheRecord() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.transient("offline")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: false, bank: "archivo") }
        #expect(backend.calls.map(\.bank) == ["archivo"])
        #expect(try decode(HindsightRequestMarker.self, dir, SessionFiles.hindsightRequested).bank == "archivo")

        // The transient failure is retried by the sweep — same bank.
        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        #expect(backend.calls.map(\.bank) == ["archivo", "archivo"])
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).bank == "archivo")
    }

    @Test func aPlainSendRecordsTheDefaultBankExplicitly() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.transient("offline")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: false) }
        #expect(try decode(HindsightRequestMarker.self, dir, SessionFiles.hindsightRequested).bank == "meetingvox")
    }

    /// Review focus 4.
    @Test func aSentSessionNeverMovesBank() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: false, bank: "archivo") }
        try rewriteTranscript(dir, "segunda versión")
        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        try await settle(probe) { await coordinator.send(dir, force: true) }
        try rewriteTranscript(dir, "tercera versión")
        // A stale menu offering another bank for an already-sent session.
        try await settle(probe) { await coordinator.send(dir, force: false, bank: "tercero") }

        #expect(backend.calls.map(\.bank) == ["archivo", "archivo", "archivo", "archivo"])
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).bank == "archivo")
    }

    @Test func aRecordWithoutABankBelongsToTheDefault() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1405", contentHash: "old", operationID: "op", sentAt: probe.now),
            dir, SessionFiles.hindsightSent
        )
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        #expect(backend.calls.map(\.bank) == ["meetingvox"])
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).bank == "meetingvox")
    }

    /// Review focus 3: the rejection removes the request marker, so the
    /// bank must survive in `hindsight.error`.
    @Test func retryAfterARejectionGoesToTheRejectedBank() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight(script: [.rejected(status: 422, message: "bad")])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.send(dir, force: false, bank: "archivo") }
        #expect(!SessionFiles.exists(SessionFiles.hindsightRequested, in: dir))
        #expect(try decode(HindsightErrorRecord.self, dir, SessionFiles.hindsightError).bank == "archivo")

        try await settle(probe) { await coordinator.retryNow(dir) }
        #expect(backend.calls.map(\.bank) == ["archivo", "archivo"])
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).bank == "archivo")
    }

    @Test func automaticSendsGoToTheDefaultBank() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(backend.calls.map(\.bank) == ["meetingvox"])
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).bank == "meetingvox")
    }

    // MARK: - Bank edge cases

    /// Fix 1: a v2 record without a bank must be frozen to the config
    /// default at the time it's first swept — a later default change must
    /// not move it.
    @Test func bankLessRecordFreezesBeforeALaterDefaultChangeTakesEffect() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1405", contentHash: "old", operationID: "op", sentAt: Date(timeIntervalSince1970: 1_700_000_000)),
            dir, SessionFiles.hindsightSent
        )
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let bankBox = BankBox("meetingvox")
        let coordinator = await makeCoordinator(backend, probe, autoSend: false, bankBox: bankBox)

        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).bank == "meetingvox")

        // The default changes after the backfilling sweep.
        bankBox.current = "otro"
        try await settle(probe) { await coordinator.send(dir, force: true) }

        #expect(backend.calls.map(\.bank) == ["meetingvox", "meetingvox"])
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).bank == "meetingvox")
    }

    @Test func backfillIsIdempotentAndLogsOnlyOnce() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1405", contentHash: "old", operationID: "op", sentAt: Date(timeIntervalSince1970: 1_700_000_000)),
            dir, SessionFiles.hindsightSent
        )
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, autoSend: false)

        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).bank == "meetingvox")
        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).bank == "meetingvox")

        let log = try String(contentsOf: dir.appendingPathComponent(SessionFiles.hindsightLog), encoding: .utf8)
        #expect(log.components(separatedBy: "backfilled hindsight.json's bank").count - 1 == 1)
    }

    @Test func aRecordAlreadyCarryingABankIsUntouchedByBackfill() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        let before = try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent)
        #expect(before.bank == "meetingvox")

        try await settle(probe) { await coordinator.sweep(root: fixture.root) }
        let after = try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent)
        #expect(after == before)

        let log = try String(contentsOf: dir.appendingPathComponent(SessionFiles.hindsightLog), encoding: .utf8)
        #expect(!log.contains("backfilled"))
    }

    /// Backfilling is pure local file stamping
    /// (no network, no token) — it must run even while the integration is
    /// off, so a bank-less record is frozen at the first sweep after
    /// upgrading regardless of that guard.
    @Test func backfillRunsEvenWhileTheIntegrationIsOff() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1405", contentHash: "old", operationID: "op", sentAt: Date(timeIntervalSince1970: 1_700_000_000)),
            dir, SessionFiles.hindsightSent
        )
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe, enabled: false, autoSend: false)

        await coordinator.sweep(root: fixture.root)

        #expect(try decode(HindsightSentRecord.self, dir, SessionFiles.hindsightSent).bank == "meetingvox")
        #expect(backend.calls.isEmpty, "no network: the integration is off")
    }

    /// Same fix, the other guard: backfilling must also run while sends are
    /// paused on a rejected token.
    @Test func backfillRunsEvenWhileSendsArePausedOnARejectedToken() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let other = try fixture.session("2026.09.23-1600", pending: false)
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1600", contentHash: "old", operationID: "op", sentAt: Date(timeIntervalSince1970: 1_700_000_000)),
            other, SessionFiles.hindsightSent
        )
        let backend = FakeHindsight(script: [.unauthorized(status: 401)])
        let probe = HindsightProbe()
        let coordinator = await makeCoordinator(backend, probe)

        try await settle(probe) { await coordinator.request(dir) }
        #expect(await coordinator.authPaused)

        await coordinator.sweep(root: fixture.root)

        #expect(try decode(HindsightSentRecord.self, other, SessionFiles.hindsightSent).bank == "meetingvox")
    }

    /// Fix 2: the "no bank configured" report must not fire for a session
    /// that was never going to be sent anyway (manual mode, unsubscribed).
    @Test func unsubscribedManualSessionWithNoDefaultBankStaysSilent() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let bankBox = BankBox(nil)
        let coordinator = await makeCoordinator(backend, probe, autoSend: false, bankBox: bankBox)

        try await settle(probe) { await coordinator.request(dir) }

        #expect(backend.calls.isEmpty)
        #expect(hindsightFiles(dir).isEmpty)
    }

    /// Fix 4: a differing bank offered for an already-sent session is
    /// ignored, but that must be visible in the session's own log.
    @Test func aDifferingBankOnAnAlreadySentSessionIsLoggedAndIgnored() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1405", contentHash: "h", operationID: "op", sentAt: probe.now, bank: "archivo"),
            dir, SessionFiles.hindsightSent
        )
        // No token: `run()` returns before it can consume (and remove) the
        // request marker, so we can inspect exactly what `send()` wrote.
        let coordinator = await makeCoordinator(backend, probe, autoSend: false, token: nil)

        try await settle(probe) { await coordinator.send(dir, force: false, bank: "otro") }

        #expect(try decode(HindsightRequestMarker.self, dir, SessionFiles.hindsightRequested).bank == "archivo")
        let log = try String(contentsOf: dir.appendingPathComponent(SessionFiles.hindsightLog), encoding: .utf8)
        #expect(log.contains("stays in archivo"))
    }

    // MARK: - Delete from memory

    private func sentSession(_ fixture: SessionFixture, bank: String? = "archivo", at probe: HindsightProbe) throws -> URL {
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1405", contentHash: "h", operationID: "op", sentAt: probe.now, bank: bank),
            dir, SessionFiles.hindsightSent
        )
        return dir
    }

    @Test func deletesTheSentDocumentFromItsRecordedBank() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let dir = try sentSession(fixture, at: probe)
        let coordinator = await makeCoordinator(backend, probe)

        let result = await coordinator.deleteFromMemory(dir)

        #expect(result == .deleted)
        #expect(backend.deleteCalls == [.init(bank: "archivo", documentID: "mv-2026.09.23-1405", token: "s3cret-token")])
    }

    @Test func aBankLessRecordDeletesFromTheDefaultBank() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let dir = try sentSession(fixture, bank: nil, at: probe)
        let coordinator = await makeCoordinator(backend, probe)

        _ = await coordinator.deleteFromMemory(dir)

        #expect(backend.deleteCalls.first?.bank == "meetingvox")
    }

    @Test func aMissingDocumentCountsAsDeleted() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight()
        backend.scriptDeletes([.deleted])  // the client maps 404 to .deleted
        let probe = HindsightProbe()
        let dir = try sentSession(fixture, at: probe)
        let coordinator = await makeCoordinator(backend, probe)

        #expect(await coordinator.deleteFromMemory(dir) == .deleted)
    }

    @Test func aDocumentIDThatIsNotThisSessionsIsRefusedAndNothingIsSent() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2099.01.01-0000", contentHash: "h", operationID: "op", sentAt: probe.now, bank: "archivo"),
            dir, SessionFiles.hindsightSent
        )
        let coordinator = await makeCoordinator(backend, probe)

        #expect(await coordinator.deleteFromMemory(dir) == .failed("document id does not match this session"))
        #expect(backend.deleteCalls.isEmpty)
    }

    @Test(arguments: ["a/b", "..", "x/../y", "mv-2026.09.23-1405/../../banks"])
    func aBankOrDocumentIDWithPathPiecesIsRefusedBeforeBuildingTheRequest(bad: String) async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let dir = try sentSession(fixture, bank: bad, at: probe)
        let coordinator = await makeCoordinator(backend, probe)

        if case .failed = await coordinator.deleteFromMemory(dir) {} else {
            Issue.record("expected a failure for bank \(bad)")
        }
        #expect(backend.deleteCalls.isEmpty)
    }

    @Test func aDocumentIDWithPathPiecesIsRefused() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1405/../x", contentHash: "h", operationID: "op", sentAt: probe.now, bank: "archivo"),
            dir, SessionFiles.hindsightSent
        )
        let coordinator = await makeCoordinator(backend, probe)

        if case .failed = await coordinator.deleteFromMemory(dir) {} else { Issue.record("expected a failure") }
        #expect(backend.deleteCalls.isEmpty)
    }

    @Test func aSessionThatWasNeverSentHasNothingToDelete() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let coordinator = await makeCoordinator(backend, probe)

        #expect(await coordinator.deleteFromMemory(dir) == .notInMemory)
        #expect(backend.deleteCalls.isEmpty)
    }

    @Test func unauthorizedFailsWithoutPausingSends() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight()
        backend.scriptDeletes([.unauthorized(status: 401)])
        let probe = HindsightProbe()
        let dir = try sentSession(fixture, at: probe)
        let coordinator = await makeCoordinator(backend, probe)

        let result = await coordinator.deleteFromMemory(dir)

        #expect(result == .failed("unauthorized (HTTP 401)"))
        #expect(await coordinator.authPaused == false)
        #expect(probe.auth.isEmpty)
    }

    @Test func transientAndRejectedFailuresAreReported() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight()
        backend.scriptDeletes([.transient("HTTP 503"), .rejected(status: 422, message: "bad")])
        let probe = HindsightProbe()
        let dir = try sentSession(fixture, at: probe)
        let coordinator = await makeCoordinator(backend, probe)

        #expect(await coordinator.deleteFromMemory(dir) == .failed("transient (HTTP 503)"))
        #expect(await coordinator.deleteFromMemory(dir) == .failed("rejected (HTTP 422: bad)"))
    }

    @Test func noTokenOrIntegrationOffFailsWithoutCallingTheServer() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight()
        let probe = HindsightProbe()
        let dir = try sentSession(fixture, at: probe)

        let noToken = await makeCoordinator(backend, probe, token: nil)
        if case .failed = await noToken.deleteFromMemory(dir) {} else { Issue.record("expected a failure without a token") }

        let off = await makeCoordinator(backend, probe, enabled: false)
        if case .failed = await off.deleteFromMemory(dir) {} else { Issue.record("expected a failure with the integration off") }

        #expect(backend.deleteCalls.isEmpty)
    }

    @Test func deletingDropsAQueuedSendForTheSession() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight(holdFirst: true)
        let probe = HindsightProbe()
        let first = try fixture.session("2026.09.23-1405", pending: false)
        let second = try fixture.session("2026.09.24-1000", pending: false)
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.24-1000", contentHash: "h", operationID: "op", sentAt: probe.now, bank: "meetingvox"),
            second, SessionFiles.hindsightSent
        )
        let coordinator = await makeCoordinator(backend, probe)

        await coordinator.request(first)
        try await waitUntil { backend.isHolding }
        await coordinator.request(second)  // queued behind the held send
        _ = await coordinator.deleteFromMemory(second)
        backend.release()
        try await waitUntil { probe.idleCount > 0 }

        #expect(backend.calls.count == 1)
        #expect(backend.deleteCalls.count == 1)
    }

    /// Defense in depth: a session queued behind a held send whose folder is
    /// then trashed is dropped — nothing sent, no notice, no attempt, and the
    /// folder is not recreated.
    @Test func aQueuedSessionWhoseFolderWasTrashedIsDroppedSilently() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight(holdFirst: true)
        let probe = HindsightProbe()
        let first = try fixture.session("2026.09.23-1405", pending: false)
        let second = try fixture.session("2026.09.24-1000", pending: false)
        let coordinator = await makeCoordinator(backend, probe)

        await coordinator.request(first)
        try await waitUntil { backend.isHolding }
        await coordinator.request(second)
        try FileManager.default.removeItem(at: second)
        backend.release()
        try await waitUntil { probe.idleCount > 0 }

        #expect(backend.calls.count == 1)
        #expect(probe.attempts == [first])
        #expect(probe.notices.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func theTokenNeverReachesTheSessionLog() async throws {
        let fixture = try SessionFixture()
        let backend = FakeHindsight()
        backend.scriptDeletes([.unauthorized(status: 401)])
        let probe = HindsightProbe()
        let dir = try sentSession(fixture, at: probe)
        let coordinator = await makeCoordinator(backend, probe)

        _ = await coordinator.deleteFromMemory(dir)

        let log = (try? String(contentsOf: dir.appendingPathComponent(SessionFiles.hindsightLog), encoding: .utf8)) ?? ""
        #expect(!log.contains("s3cret-token"))
    }
}
