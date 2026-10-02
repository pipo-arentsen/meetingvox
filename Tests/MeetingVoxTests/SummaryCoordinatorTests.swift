import Foundation
import Testing
@testable import MeetingVox

// MARK: - Fakes

/// Scripted OpenRouter: each `complete` call pops the next result (a default
/// valid JSON summary once the script runs out).
private final class SummaryFakeBackend: MinutesBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<String, OpenRouterError>]
    private var _calls: [[ChatMessage]] = []
    private var modelsFailures: Int
    let contextLength: Int?

    init(script: [Result<String, OpenRouterError>] = [], contextLength: Int? = 128_000, modelsFailures: Int = 0) {
        self.script = script
        self.contextLength = contextLength
        self.modelsFailures = modelsFailures
    }

    var calls: [[ChatMessage]] { lock.withLock { _calls } }

    func models() async throws -> [OpenRouterModel] {
        let fail: Bool = lock.withLock {
            guard modelsFailures > 0 else { return false }
            modelsFailures -= 1
            return true
        }
        if fail { throw OpenRouterError.transport("catalog offline") }
        return [OpenRouterModel(id: "m/x", name: "X", contextLength: contextLength, promptPrice: nil, completionPrice: nil)]
    }

    func complete(
        apiKey: String, model: String, messages: [ChatMessage], maxTokens: Int, denyDataCollection: Bool
    ) async throws -> String {
        let next: Result<String, OpenRouterError> = lock.withLock {
            _calls.append(messages)
            if !script.isEmpty { return script.removeFirst() }
            return .success(SummaryFakeBackend.defaultReply)
        }
        return try next.get()
    }

    static let defaultReply = #"{"title": "Kickoff", "summary": "Resumen breve.", "client": "Proveedor", "topics": ["alcance"], "participants": ["Participante 1"]}"#
}

private struct SummaryFixedKey: APIKeyStore {
    var present = true
    func hasAPIKey() -> Bool { present }
    func read() throws -> String? { present ? "sk-test" : nil }
    func save(_ secret: String) throws {}
    func delete() throws {}
}

private final class SummaryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    private var _sleeps: [TimeInterval] = []
    private var _notifications: [String] = []
    private var _notices: [Notice] = []
    private var _statuses: [SummaryCoordinator.Status] = []
    private var _indexChanges = 0

    var now: Date { lock.withLock { _now } }
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }
    var notifications: [String] { lock.withLock { _notifications } }
    var notices: [Notice] { lock.withLock { _notices } }
    var statuses: [SummaryCoordinator.Status] { lock.withLock { _statuses } }
    var indexChanges: Int { lock.withLock { _indexChanges } }

    func sleep(_ seconds: TimeInterval) {
        lock.withLock {
            _sleeps.append(seconds)
            _now = _now.addingTimeInterval(seconds)
        }
    }
    func notify(_ notice: Notice) {
        lock.withLock {
            _notifications.append(notice.title)
            _notices.append(notice)
        }
    }
    func status(_ s: SummaryCoordinator.Status) { lock.withLock { _statuses.append(s) } }
    func indexChanged() { lock.withLock { _indexChanges += 1 } }
}

private func summaryConfig(
    enabled: Bool = true, model: String? = "m/x", glossary: Bool = false
) -> @Sendable () -> ConfigValues {
    {
        var raw: [String: Any] = ["summary": ["enabled": enabled]]
        if let model { raw["openrouter"] = ["model": model] }
        if glossary { raw["glossary"] = ["Kubernetes", ["term": "Kafka", "variants": ["cafca", "kafca"]]] }
        return ConfigValues(raw: raw)
    }
}

private func makeSummaryCoordinator(
    backend: SummaryFakeBackend, probe: SummaryProbe, enabled: Bool = true, model: String? = "m/x", hasKey: Bool = true,
    glossary: Bool = false
) async -> SummaryCoordinator {
    let env = SummaryCoordinator.Environment(
        backend: backend,
        keyStore: SummaryFixedKey(present: hasKey),
        config: summaryConfig(enabled: enabled, model: model, glossary: glossary),
        now: { probe.now },
        sleep: { probe.sleep($0) },
        notify: { probe.notify($0) },
        timeZone: TimeZone(identifier: "UTC")!,
        indexDidChange: { probe.indexChanged() }
    )
    let coordinator = SummaryCoordinator(environment: env)
    await coordinator.setStatusHandler { probe.status($0) }
    return coordinator
}

private func summaryFinished(_ probe: SummaryProbe, runs: Int = 1) -> Bool {
    probe.statuses.filter {
        switch $0 {
        case .idle, .failed: true
        default: false
        }
    }.count >= runs
}

private func exists(_ name: String, _ dir: URL) -> Bool { SessionFiles.exists(name, in: dir) }

/// Session folders `didFinish` was called with, in order.
private final class FinishedDirs: @unchecked Sendable {
    private let lock = NSLock()
    private var _dirs: [URL] = []
    var dirs: [URL] { lock.withLock { _dirs } }
    func append(_ dir: URL) { lock.withLock { _dirs.append(dir) } }
}

// MARK: - Fixtures

/// A minimal session: meta.json + transcript.json (no minutes markers).
private func summarySession(_ fixture: SessionFixture, _ name: String, transcript: Bool = true) throws -> URL {
    try fixture.session(name, transcript: transcript, pending: false)
}

private func longSummarySession(_ fixture: SessionFixture, lines: Int) throws -> URL {
    let dir = fixture.root.appendingPathComponent("largo-resumen", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"duration_seconds": 600}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
    let segments = (0..<lines).map { i in
        #"{"speaker": "\#(i % 2 == 0 ? "me" : "them")", "start_ms": \#(i * 10_000), "end_ms": \#(i * 10_000 + 9_000), "text": "\#(String(repeating: "palabra ", count: 25))"}"#
    }
    try Data(#"{"segments": [\#(segments.joined(separator: ","))]}"#.utf8)
        .write(to: dir.appendingPathComponent("transcript.json"))
    return dir
}

// MARK: - SummaryCoordinator

@Suite struct SummaryCoordinatorTests {
    @Test func reindexAsksForOneIndexRegenerationAndNothingElse() async {
        let probe = SummaryProbe()
        let backend = SummaryFakeBackend()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)
        await coordinator.reindex()
        #expect(probe.indexChanges == 1)
        await coordinator.reindex()
        #expect(probe.indexChanges == 2)
        #expect(backend.calls.isEmpty)
    }

    @Test func requestWritesSummaryJSONFromTranscript() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        #expect(exists(SessionFiles.summaryJSON, dir))
        #expect(!exists(SessionFiles.summaryPending, dir))
        let data = try Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(MeetingSummary.self, from: data)
        #expect(summary.title == "Kickoff")
        #expect(summary.source == .transcript)
        #expect(summary.model == "m/x")
        #expect(probe.indexChanges == 1)
        #expect(backend.calls[0][1].content.contains("[00:00] Yo: Hola"))
        // No per-stage "resumen listo"; the settlement notifier owns the ready notice.
        #expect(probe.notices.isEmpty)
    }

    @Test func requestUsesMinutesWhenAvailable() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        try Data("# Minuta\n\nContenido de la minuta.".utf8).write(to: dir.appendingPathComponent("minuta.md"))
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        let data = try Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(MeetingSummary.self, from: data)
        #expect(summary.source == .minutes)
        #expect(backend.calls[0][1].content.contains("Contenido de la minuta"))
    }

    @Test func invalidJSONRetriesOnceThenErrors() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend(script: [.success("no soy json"), .success("tampoco esto")])
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        #expect(backend.calls.count == 2)
        #expect(exists(SessionFiles.summaryError, dir))
        #expect(!exists(SessionFiles.summaryPending, dir))
        #expect(!exists(SessionFiles.summaryJSON, dir))
        // The retry carries the stricter reminder.
        #expect(backend.calls[1][0].content.contains(SummaryPrompts.recordatorioJSON))
        // One failure notice naming the summary, without a log reference.
        #expect(probe.notices.map(\.kind) == [.failure(.summary, retryable: true)])
        #expect(probe.notices.first?.title == Textos.Notificacion.resumenFallido)
        #expect(probe.notices.first?.body == Textos.Notificacion.resumenFallidoCuerpo("s1"))
        #expect(probe.notices.first?.session == dir)
        #expect(probe.notices.allSatisfy { !$0.body.contains("revisa") && !$0.body.contains(".log") })
    }

    @Test func retryableFailureRequeuesViaRetryPolicy() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend(script: [.failure(.server(status: 503, message: nil))])
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        #expect(probe.sleeps == [30])
        #expect(backend.calls.count == 2)
        #expect(exists(SessionFiles.summaryJSON, dir))
    }

    @Test func exhaustedRetriesKeepPending() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend(script: Array(repeating: .failure(.transport("offline")), count: 4))
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        #expect(probe.sleeps == [30, 120, 600])
        #expect(exists(SessionFiles.summaryPending, dir))
        #expect(!exists(SessionFiles.summaryError, dir))
        #expect(probe.notices.map(\.body) == [Textos.Notificacion.resumenSigue("s1")])
        #expect(probe.notices.map(\.kind) == [.failure(.summary, retryable: true)])
    }

    @Test func gateSkipsWhenDisabled() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe, enabled: false)

        await coordinator.request(dir)
        try await Task.sleep(for: .milliseconds(50))

        #expect(!exists(SessionFiles.summaryPending, dir))
        #expect(backend.calls.isEmpty)
    }

    @Test func gateSkipsWithoutAPIKey() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe, hasKey: false)

        await coordinator.request(dir)
        try await Task.sleep(for: .milliseconds(50))

        #expect(!exists(SessionFiles.summaryPending, dir))
        #expect(backend.calls.isEmpty)
    }

    @Test func gateSkipsWithoutModel() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe, model: nil)

        await coordinator.request(dir)
        try await Task.sleep(for: .milliseconds(50))

        #expect(!exists(SessionFiles.summaryPending, dir))
        #expect(backend.calls.isEmpty)
    }

    @Test func gateSkipsWhenSummaryAlreadyExists() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        try SessionFiles.writeMarker(SessionFiles.summaryJSON, in: dir) // placeholder: presence is what matters here
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await Task.sleep(for: .milliseconds(50))

        #expect(!exists(SessionFiles.summaryPending, dir))
        #expect(backend.calls.isEmpty)
    }

    @Test func transcriptSourcedSummaryIsUpgradedOnceMinutesExist() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }
        #expect(backend.calls.count == 1)

        // Minutes finish later: a second request should upgrade the summary.
        try Data("# Minuta\n\nContenido.".utf8).write(to: dir.appendingPathComponent("minuta.md"))
        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe, runs: 2) }

        #expect(backend.calls.count == 2)
        let data = try Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(MeetingSummary.self, from: data)
        #expect(summary.source == .minutes)
    }

    @Test func resumePendingPicksOnlyMarkedSessions() async throws {
        let fixture = try SessionFixture()
        let marked = try summarySession(fixture, "2026.09.20-1000")
        try SessionFiles.writeMarker(SessionFiles.summaryPending, in: marked)
        let unmarked = try summarySession(fixture, "2026.09.21-1000")
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.resumePending(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        #expect(exists(SessionFiles.summaryJSON, marked))
        #expect(!exists(SessionFiles.summaryJSON, unmarked))
    }

    @Test func rebuildSkipsPendingMinutesAndExistingMarkersThenRegeneratesIndex() async throws {
        let fixture = try SessionFixture()
        let candidate = try summarySession(fixture, "2026.09.20-1000")
        let withPendingMinutes = try fixture.session("2026.09.21-1000", pending: true) // minuta.pendiente
        let withSummaryError = try summarySession(fixture, "2026.09.22-1000")
        try SessionFiles.writeMarker(SessionFiles.summaryError, in: withSummaryError)
        let noTranscript = try summarySession(fixture, "2026.09.23-1000", transcript: false)
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        #expect(exists(SessionFiles.summaryJSON, candidate))
        #expect(!exists(SessionFiles.summaryJSON, withPendingMinutes))
        #expect(!exists(SessionFiles.summaryJSON, withSummaryError))
        #expect(!exists(SessionFiles.summaryJSON, noTranscript))
        #expect(probe.indexChanges >= 1)
    }

    @Test func rebuildReEnqueuesStalledSummaryPendingSessions() async throws {
        // Simulates a session whose summary retries were exhausted earlier:
        // resumen.pendiente survives on disk, but the job left the queue —
        // it must stay resumable at next launch or by a backfill.
        let fixture = try SessionFixture()
        let stalled = try summarySession(fixture, "2026.09.20-1000")
        try SessionFiles.writeMarker(SessionFiles.summaryPending, in: stalled)
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        #expect(exists(SessionFiles.summaryJSON, stalled))
        #expect(!exists(SessionFiles.summaryPending, stalled))
        #expect(probe.indexChanges >= 1)
    }

    @Test func longTranscriptUsesChunkedReducer() async throws {
        let fixture = try SessionFixture()
        let dir = try longSummarySession(fixture, lines: 60)
        let backend = SummaryFakeBackend(contextLength: 4_000)
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        let calls = backend.calls
        #expect(calls.count >= 3)
        let partials = calls.dropLast()
        for (i, call) in partials.enumerated() {
            #expect(call[0].content.contains("parte \(i + 1) de \(partials.count)"))
        }
        #expect(exists(SessionFiles.summaryJSON, dir))
    }

    @Test func singleCallSystemPromptCarriesGlossary() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe, glossary: true)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        let system = backend.calls[0][0].content
        #expect(system.contains("corresponde al término: Kubernetes; Kafka (puede aparecer como «cafca», «kafca»)."))
    }

    @Test func minutesSourcedSummaryCarriesGlossary() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        try Data("# Minuta\n\nContenido.".utf8).write(to: dir.appendingPathComponent("minuta.md"))
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe, glossary: true)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        #expect(backend.calls[0][0].content.contains("Kafka (puede aparecer como «cafca», «kafca»)"))
    }

    @Test func chunkedSummaryCarriesGlossaryInEveryCall() async throws {
        let fixture = try SessionFixture()
        let dir = try longSummarySession(fixture, lines: 60)
        let backend = SummaryFakeBackend(contextLength: 4_000)
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe, glossary: true)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        let calls = backend.calls
        #expect(calls.count >= 3)
        for call in calls {
            #expect(call[0].content.contains("Kafka (puede aparecer como «cafca», «kafca»)"))
        }
    }

    @Test func noGlossaryMeansNoGlossaryBlock() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        #expect(!backend.calls[0][0].content.contains("Términos propios"))
    }

    @Test func replyWithoutTasksIsWrittenWithoutTheKey() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend()  // default reply has no `tasks`
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON))) as? [String: Any]
        )
        #expect(object["tasks"] == nil)
        #expect(object["title"] as? String == "Kickoff")
    }

    @Test func replyWithTasksAndCountryIsStored() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let reply = #"{"title": "T", "summary": "S", "client": "Proveedor", "topics": [], "participants": [], "country": "Alemania", "tasks": [{"who": "Participante 1", "what": "Enviar oferta", "when": "lunes"}]}"#
        let backend = SummaryFakeBackend(script: [.success(reply)])
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(
            MeetingSummary.self, from: Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON))
        )
        #expect(summary.country == "Alemania")
        #expect(summary.tasks == [MeetingTask(who: "Participante 1", what: "Enviar oferta", when: "lunes")])
    }

    @Test func singleCallSystemPromptAsksForTasksAndCountry() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        let system = backend.calls[0][0].content
        #expect(system.contains("\"tasks\"") && system.contains("\"country\""))
    }

    @Test func chunkedNotesAndReductionsKeepWhoWhatWhen() async throws {
        let fixture = try SessionFixture()
        let dir = try longSummarySession(fixture, lines: 60)
        let backend = SummaryFakeBackend(contextLength: 4_000)
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        let calls = backend.calls
        #expect(calls.count >= 3)
        for call in calls.dropLast() {
            #expect(call[0].content.contains(SummaryPrompts.tareasNotasInstrucciones))
        }
        #expect(calls.last?[0].content.contains("\"tasks\"") == true)
    }

    @Test func didFinishFiresAfterSuccessAndAfterFinalFailure() async throws {
        let fixture = try SessionFixture()
        let ok = try summarySession(fixture, "ok")
        let bad = try summarySession(fixture, "bad")
        let finished = FinishedDirs()
        let backend = SummaryFakeBackend(script: [.success(SummaryFakeBackend.defaultReply), .failure(.badRequest("no"))])
        let probe = SummaryProbe()
        let env = SummaryCoordinator.Environment(
            backend: backend,
            keyStore: SummaryFixedKey(),
            config: summaryConfig(),
            now: { probe.now },
            sleep: { probe.sleep($0) },
            notify: { probe.notify($0) },
            timeZone: TimeZone(identifier: "UTC")!,
            didFinish: { finished.append($0) }
        )
        let coordinator = SummaryCoordinator(environment: env)

        await coordinator.request(ok)
        await coordinator.request(bad)
        try await waitUntil { finished.dirs.count == 2 }

        #expect(finished.dirs == [ok, bad])
        #expect(exists(SessionFiles.summaryJSON, ok))
        #expect(!exists(SessionFiles.summaryPending, ok))
        #expect(exists(SessionFiles.summaryError, bad))
    }
}

// MARK: - Retry ("Reintentar" on a summary failure notice)

@Suite struct SummaryRetryTests {
    @Test func retryRegeneratesASummaryThatFailedForGood() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend(script: [.failure(.badRequest("no"))])
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }
        #expect(exists(SessionFiles.summaryError, dir))

        #expect(await coordinator.retry(dir))
        try await waitUntil { summaryFinished(probe, runs: 2) }

        #expect(exists(SessionFiles.summaryJSON, dir))
        #expect(!exists(SessionFiles.summaryError, dir))
        #expect(!exists(SessionFiles.summaryPending, dir))
        #expect(backend.calls.count == 2)
    }

    @Test func retryDoesNothingWhenTheGateSkipsAndKeepsTheFailureMarker() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        try SessionFiles.writeMarker(SessionFiles.summaryError, in: dir)
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: SummaryFakeBackend(), probe: probe, hasKey: false)

        #expect(await coordinator.retry(dir) == false)
        #expect(exists(SessionFiles.summaryError, dir))
        #expect(!exists(SessionFiles.summaryPending, dir))
    }

    @Test func retryDoesNothingWhenASummaryAlreadyExists() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)
        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        #expect(await coordinator.retry(dir) == false)
        #expect(backend.calls.count == 1)
    }

    @Test func retryRunsAJobThatWasWaitingForItsNextAttemptNow() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend(script: [.failure(.server(status: 503, message: nil))])
        let probe = SummaryProbe()
        // A sleep that only ends when cancelled and a clock that never moves:
        // the job stays parked at its 30 s retry until `retry` wakes it.
        let env = SummaryCoordinator.Environment(
            backend: backend, keyStore: SummaryFixedKey(), config: summaryConfig(),
            now: { probe.now }, sleep: { _ in try await Task.sleep(for: .seconds(600)) },
            notify: { probe.notify($0) }, timeZone: TimeZone(identifier: "UTC")!
        )
        let coordinator = SummaryCoordinator(environment: env)
        await coordinator.setStatusHandler { probe.status($0) }

        await coordinator.request(dir)
        try await waitUntil { probe.statuses.contains(.waitingRetry(session: "s1")) }
        #expect(!exists(SessionFiles.summaryJSON, dir))

        #expect(await coordinator.retry(dir))
        try await waitUntil { exists(SessionFiles.summaryJSON, dir) }
        #expect(backend.calls.count == 2)
    }
}


// MARK: - Tasks backfill jobs (`tareas.*`)

/// Answers the tasks-only prompt with a tasks reply and any other prompt with
/// a summary reply; can hold every call until `open()` so a test can act while
/// a job is in flight.
private final class GatedSummaryBackend: MinutesBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen: Bool
    private var _prompts: [String] = []

    init(open: Bool = false) { isOpen = open }

    var prompts: [String] { lock.withLock { _prompts } }
    var tasksCalls: Int { prompts.filter { $0.hasPrefix(SummaryPrompts.tareasRol) }.count }

    func open() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        toResume.forEach { $0.resume() }
    }

    func models() async throws -> [OpenRouterModel] {
        [OpenRouterModel(id: "m/x", name: "X", contextLength: 128_000, promptPrice: nil, completionPrice: nil)]
    }

    func complete(
        apiKey: String, model: String, messages: [ChatMessage], maxTokens: Int, denyDataCollection: Bool
    ) async throws -> String {
        let system = messages.first?.content ?? ""
        lock.withLock { _prompts.append(system) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        if system.hasPrefix(SummaryPrompts.tareasRol) {
            return #"{"tasks": [{"who": "Participante 1", "what": "Enviar oferta", "when": "lunes"}], "country": "Alemania"}"#
        }
        return #"{"title": "Nuevo", "summary": "S", "client": "Proveedor", "topics": [], "participants": []}"#
    }
}

/// Every call throws `CancellationError`, as a cancelled `Task` would.
private struct CancellingSummaryBackend: MinutesBackend {
    func models() async throws -> [OpenRouterModel] {
        [OpenRouterModel(id: "m/x", name: "X", contextLength: 128_000, promptPrice: nil, completionPrice: nil)]
    }

    func complete(
        apiKey: String, model: String, messages: [ChatMessage], maxTokens: Int, denyDataCollection: Bool
    ) async throws -> String {
        throw CancellationError()
    }
}

/// The Keychain item exists (attributes) but its secret reads as nothing.
private struct SummaryUnreadableKey: APIKeyStore {
    func hasAPIKey() -> Bool { true }
    func read() throws -> String? { nil }
    func save(_ secret: String) throws {}
    func delete() throws {}
}

private let legacySummaryJSON = """
{"title": "Kickoff", "summary": "Resumen.", "client": "Proveedor", "topics": ["alcance"], "participants": ["Participante 1"], \
"source": "transcript", "model": "m/x", "generated_at": "2026-09-20T10:00:00Z", "extra": {"k": [1, 2]}}
"""

/// A session with a legacy `resumen.json` (no `tasks` key).
private func legacySession(_ fixture: SessionFixture, _ name: String, json: String = legacySummaryJSON) throws -> URL {
    let dir = try summarySession(fixture, name)
    try Data(json.utf8).write(to: dir.appendingPathComponent(SessionFiles.summaryJSON))
    return dir
}

private func summaryObject(_ dir: URL) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON))) as? [String: Any]
    )
}

private func makeTasksCoordinator(
    backend: any MinutesBackend, probe: SummaryProbe, finished: FinishedDirs = FinishedDirs(),
    sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil
) async -> SummaryCoordinator {
    let env = SummaryCoordinator.Environment(
        backend: backend, keyStore: SummaryFixedKey(), config: summaryConfig(),
        now: { probe.now }, sleep: sleep ?? { probe.sleep($0) },
        notify: { probe.notify($0) }, timeZone: TimeZone(identifier: "UTC")!,
        indexDidChange: { probe.indexChanged() }, didFinish: { finished.append($0) }
    )
    let coordinator = SummaryCoordinator(environment: env)
    await coordinator.setStatusHandler { probe.status($0) }
    return coordinator
}

private func noSummaryStatus(_ probe: SummaryProbe) -> Bool {
    !probe.statuses.contains {
        switch $0 {
        case .generating, .waitingRetry, .failed: true
        default: false
        }
    }
}

@Suite struct SummaryTasksJobTests {
    @Test func rebuildBackfillsLegacySummariesOnceAndKeepsEveryOtherField() async throws {
        let fixture = try SessionFixture()
        let a = try legacySession(fixture, "2026.09.20-1000")
        let b = try legacySession(fixture, "2026.09.21-1000")
        let backend = GatedSummaryBackend(open: true)
        let probe = SummaryProbe()
        let finished = FinishedDirs()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe, finished: finished)

        await coordinator.rebuild(root: fixture.root)
        // The marker exists as soon as rebuild returns: the filesystem is the queue.
        try await waitUntil { summaryFinished(probe) }

        for dir in [a, b] {
            let object = try summaryObject(dir)
            #expect(object["client"] as? String == "Proveedor")
            #expect(object["title"] as? String == "Kickoff")
            #expect((object["extra"] as? [String: Any])?["k"] as? [Int] == [1, 2])
            #expect(object["country"] as? String == "Alemania")
            let tasks = try #require(object["tasks"] as? [[String: Any]])
            #expect(tasks.first?["what"] as? String == "Enviar oferta")
            #expect(!exists(SessionFiles.tasksPending, dir))
        }
        #expect(backend.tasksCalls == 2)
        #expect(probe.notices.isEmpty)
        #expect(finished.dirs.isEmpty)

        await coordinator.rebuild(root: fixture.root)
        #expect(!exists(SessionFiles.tasksPending, a) && !exists(SessionFiles.tasksPending, b))
        #expect(backend.prompts.count == 2)
    }

    @Test func rebuildWritesTheTasksMarkerForEverySessionItQueues() async throws {
        let fixture = try SessionFixture()
        let a = try legacySession(fixture, "2026.09.20-1000")
        let b = try legacySession(fixture, "2026.09.21-1000")
        let backend = GatedSummaryBackend()  // held: jobs stay queued/running
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe)

        await coordinator.rebuild(root: fixture.root)

        #expect(exists(SessionFiles.tasksPending, a))
        #expect(exists(SessionFiles.tasksPending, b))
        backend.open()
        try await waitUntil { summaryFinished(probe) }
    }

    @Test func rebuildSkipsAFailedBackfillAndSessionsWithTasks() async throws {
        let fixture = try SessionFixture()
        let failed = try legacySession(fixture, "2026.09.20-1000")
        try SessionFiles.writeMarker(SessionFiles.tasksError, in: failed)
        let done = try legacySession(fixture, "2026.09.21-1000", json: #"{"title": "T", "summary": "S", "tasks": []}"#)
        let backend = GatedSummaryBackend(open: true)
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe)

        await coordinator.rebuild(root: fixture.root)

        #expect(!exists(SessionFiles.tasksPending, failed))
        #expect(!exists(SessionFiles.tasksPending, done))
        #expect(backend.prompts.isEmpty)
    }

    @Test func launchResumesOnlyStalledTasksJobs() async throws {
        let fixture = try SessionFixture()
        let legacy = try legacySession(fixture, "2026.09.20-1000")
        let stalled = try legacySession(fixture, "2026.09.21-1000")
        try SessionFiles.writeMarker(SessionFiles.tasksPending, in: stalled)
        let backend = GatedSummaryBackend(open: true)
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe)

        await coordinator.resumePending(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        #expect(try summaryObject(stalled)["tasks"] != nil)
        #expect(try summaryObject(legacy)["tasks"] == nil)
        #expect(backend.prompts.count == 1)
        #expect(!exists(SessionFiles.tasksPending, stalled))
    }

    @Test func exhaustedRetriesKeepTheMarkerWithoutAnyNoticeOrSummaryStatus() async throws {
        let fixture = try SessionFixture()
        let dir = try legacySession(fixture, "s1")
        let before = try Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON))
        let backend = SummaryFakeBackend(script: Array(repeating: .failure(.transport("offline")), count: 4))
        let probe = SummaryProbe()
        let finished = FinishedDirs()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe, finished: finished)

        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        #expect(probe.sleeps == [30, 120, 600])
        #expect(exists(SessionFiles.tasksPending, dir))
        #expect(!exists(SessionFiles.tasksError, dir))
        #expect(try Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON)) == before)
        #expect(probe.notices.isEmpty)
        #expect(finished.dirs.isEmpty)
        #expect(noSummaryStatus(probe))
        #expect(probe.statuses.last == .idle)
    }

    @Test func invalidJSONTwiceWritesTareasErrorAndLeavesTheSummaryUntouched() async throws {
        let fixture = try SessionFixture()
        let dir = try legacySession(fixture, "s1")
        let before = try Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON))
        let backend = SummaryFakeBackend(script: [.success("no es json"), .success("tampoco")])
        let probe = SummaryProbe()
        let finished = FinishedDirs()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe, finished: finished)

        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        #expect(exists(SessionFiles.tasksError, dir))
        #expect(!exists(SessionFiles.tasksPending, dir))
        #expect(try Data(contentsOf: dir.appendingPathComponent(SessionFiles.summaryJSON)) == before)
        #expect(probe.notices.isEmpty)
        #expect(finished.dirs.isEmpty)
        #expect(noSummaryStatus(probe))
        #expect(probe.statuses.last == .idle)
        // The failed session is not a candidate any more.
        await coordinator.rebuild(root: fixture.root)
        #expect(!exists(SessionFiles.tasksPending, dir))
    }

    @Test(arguments: [OpenRouterError.outputTruncated, .emptyContent])
    func aContentSpecificModelFailureWritesTareasError(_ failure: OpenRouterError) async throws {
        let fixture = try SessionFixture()
        let dir = try legacySession(fixture, "s1")
        let backend = SummaryFakeBackend(script: [.failure(failure)])
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe)

        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        #expect(exists(SessionFiles.tasksError, dir))
        #expect(!exists(SessionFiles.tasksPending, dir))
    }

    @Test(arguments: [OpenRouterError.unauthorized("key"), .insufficientCredits(nil), .badRequest("model"), .unexpectedStatus(418, nil)])
    func anAccountFailureKeepsTheMarkersPendingAndSkipsTheRestOfThePass(_ failure: OpenRouterError) async throws {
        let fixture = try SessionFixture()
        let a = try legacySession(fixture, "2026.09.20-1000")
        let b = try legacySession(fixture, "2026.09.21-1000")
        let tasksReply = #"{"tasks": []}"#
        let backend = SummaryFakeBackend(script: [.failure(failure), .success(tasksReply), .success(tasksReply)])
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe)

        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        #expect(backend.calls.count == 1, "the remaining tasks jobs never reach the model")
        for dir in [a, b] {
            #expect(exists(SessionFiles.tasksPending, dir))
            #expect(!exists(SessionFiles.tasksError, dir))
        }
        // A later rebuild (the account fixed) tries them again.
        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { summaryFinished(probe, runs: 2) }
        #expect(!exists(SessionFiles.tasksPending, a) && !exists(SessionFiles.tasksPending, b))
        #expect(try summaryObject(a)["tasks"] != nil && summaryObject(b)["tasks"] != nil)
    }

    @Test func aCancelledAttemptKeepsTheMarkerPendingWithoutTareasError() async throws {
        let fixture = try SessionFixture()
        let a = try legacySession(fixture, "2026.09.20-1000")
        let b = try legacySession(fixture, "2026.09.21-1000")
        let before = try Data(contentsOf: a.appendingPathComponent(SessionFiles.summaryJSON))
        let probe = SummaryProbe()
        let finished = FinishedDirs()
        let coordinator = await makeTasksCoordinator(backend: CancellingSummaryBackend(), probe: probe, finished: finished)

        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        for dir in [a, b] {
            #expect(exists(SessionFiles.tasksPending, dir))
            #expect(!exists(SessionFiles.tasksError, dir))
        }
        #expect(try Data(contentsOf: a.appendingPathComponent(SessionFiles.summaryJSON)) == before)
        #expect(probe.sleeps.isEmpty, "a cancellation is not retried")
        #expect(probe.notices.isEmpty)
        #expect(finished.dirs.isEmpty)
        #expect(noSummaryStatus(probe))
        // A later rebuild still sees both as candidates.
        await coordinator.rebuild(root: fixture.root)
        #expect(exists(SessionFiles.tasksPending, a) && exists(SessionFiles.tasksPending, b))
    }

    @Test func aKeychainThatReadsNothingKeepsTheMarkerPending() async throws {
        let fixture = try SessionFixture()
        let dir = try legacySession(fixture, "s1")
        let probe = SummaryProbe()
        let env = SummaryCoordinator.Environment(
            backend: SummaryFakeBackend(), keyStore: SummaryUnreadableKey(), config: summaryConfig(),
            now: { probe.now }, sleep: { probe.sleep($0) }, notify: { probe.notify($0) },
            timeZone: TimeZone(identifier: "UTC")!, indexDidChange: { probe.indexChanged() }
        )
        let coordinator = SummaryCoordinator(environment: env)
        await coordinator.setStatusHandler { probe.status($0) }

        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        #expect(exists(SessionFiles.tasksPending, dir))
        #expect(!exists(SessionFiles.tasksError, dir))
    }

    @Test func aSummaryRequestedWhileTasksJobsAreQueuedRunsNext() async throws {
        let fixture = try SessionFixture()
        for day in 20...23 { _ = try legacySession(fixture, "2026.09.\(day)-1000") }
        let backend = GatedSummaryBackend()
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe)

        // The first tasks job (the last one queued is the oldest) blocks in the model call.
        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { backend.prompts.count == 1 }
        let fresh = try summarySession(fixture, "2026.09.30-1000")
        await coordinator.request(fresh)
        backend.open()
        try await waitUntil { summaryFinished(probe) }

        #expect(backend.prompts.count == 5)
        #expect(backend.prompts[0].hasPrefix(SummaryPrompts.tareasRol))
        #expect(!backend.prompts[1].hasPrefix(SummaryPrompts.tareasRol), "the summary jumps the three waiting tasks jobs")
        #expect(exists(SessionFiles.summaryJSON, fresh))
    }

    @Test func aWaitingTasksJobPublishesExtractingTasksNotAWaitingSummary() async throws {
        let fixture = try SessionFixture()
        _ = try legacySession(fixture, "s1")
        let backend = SummaryFakeBackend(script: [.failure(.server(status: 503, message: nil))])
        let probe = SummaryProbe()
        // A sleep that only ends when cancelled: the job stays parked at its retry.
        let coordinator = await makeTasksCoordinator(
            backend: backend, probe: probe, sleep: { _ in try await Task.sleep(for: .seconds(600)) }
        )

        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { probe.statuses.filter { $0 == .extractingTasks(session: "s1", queued: 0) }.count >= 2 }

        #expect(noSummaryStatus(probe))
    }

    @Test func aSuccessfulSummaryClearsTheTasksMarkers() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        try SessionFiles.writeMarker(SessionFiles.tasksPending, in: dir)
        try SessionFiles.writeMarker(SessionFiles.tasksError, in: dir)
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: SummaryFakeBackend(), probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        #expect(exists(SessionFiles.summaryJSON, dir))
        #expect(!exists(SessionFiles.tasksPending, dir))
        #expect(!exists(SessionFiles.tasksError, dir))
    }

    @Test func aTasksMarkerIsIgnoredWhileTheSameSessionOwesASummary() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        try SessionFiles.writeMarker(SessionFiles.summaryPending, in: dir)
        try SessionFiles.writeMarker(SessionFiles.tasksPending, in: dir)
        let backend = GatedSummaryBackend(open: true)
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe)

        await coordinator.resumePending(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        #expect(backend.tasksCalls == 0)
        #expect(backend.prompts.count == 1)
        #expect(!exists(SessionFiles.tasksPending, dir))
    }

    @Test func aStalledJobWhoseSummaryAlreadyHasTasksIsDroppedBeforeTheModelCall() async throws {
        let fixture = try SessionFixture()
        let dir = try legacySession(fixture, "s1", json: #"{"title": "T", "summary": "S", "tasks": []}"#)
        try SessionFiles.writeMarker(SessionFiles.tasksPending, in: dir)
        let backend = GatedSummaryBackend(open: true)
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe)

        await coordinator.resumePending(root: fixture.root)
        try await waitUntil { summaryFinished(probe) }

        #expect(backend.prompts.isEmpty)
        #expect(!exists(SessionFiles.tasksPending, dir))
        #expect(!exists(SessionFiles.tasksError, dir))
    }

    @Test func mergeReReadsTheFileJustBeforeWriting() async throws {
        let fixture = try SessionFixture()
        let dir = try legacySession(fixture, "s1")
        let backend = GatedSummaryBackend()
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe)

        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { backend.tasksCalls == 1 }
        // The summary changes while the model call is in flight.
        try Data(legacySummaryJSON.replacingOccurrences(of: "Kickoff", with: "Editado").utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.summaryJSON))
        backend.open()
        try await waitUntil { summaryFinished(probe) }

        let object = try summaryObject(dir)
        #expect(object["title"] as? String == "Editado")
        #expect(object["tasks"] != nil)
    }

    @Test func aTasksKeyWrittenMeanwhileRefusesTheMergeWithoutFailing() async throws {
        let fixture = try SessionFixture()
        let dir = try legacySession(fixture, "s1")
        let backend = GatedSummaryBackend()
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe)

        await coordinator.rebuild(root: fixture.root)
        try await waitUntil { backend.tasksCalls == 1 }
        try Data(#"{"title": "T", "summary": "S", "tasks": [{"what": "Otra"}]}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.summaryJSON))
        backend.open()
        try await waitUntil { summaryFinished(probe) }

        let tasks = try #require(summaryObject(dir)["tasks"] as? [[String: Any]])
        #expect(tasks.first?["what"] as? String == "Otra")
        #expect(!exists(SessionFiles.tasksPending, dir))
        #expect(!exists(SessionFiles.tasksError, dir))
    }

    @Test func summaryRetryIsAdmittedBesideARunningAndAQueuedTasksJob() async throws {
        let fixture = try SessionFixture()
        // Both sessions can take a summary upgrade (transcript-sourced + minutes)
        // so the summary request gate admits them.
        let running = try legacySession(fixture, "2026.09.20-1000")
        let queued = try legacySession(fixture, "2026.09.21-1000")
        for dir in [running, queued] {
            try Data("# Minuta".utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes))
            try SessionFiles.writeMarker(SessionFiles.tasksPending, in: dir)  // stalled tasks jobs
        }
        let backend = GatedSummaryBackend()
        let probe = SummaryProbe()
        let coordinator = await makeTasksCoordinator(backend: backend, probe: probe)

        await coordinator.resumePending(root: fixture.root)
        try await waitUntil { backend.tasksCalls == 1 }  // first job runs (blocked), second is queued
        for dir in [running, queued] {
            try SessionFiles.writeMarker(SessionFiles.summaryError, in: dir)
        }

        #expect(await coordinator.retry(running))
        #expect(await coordinator.retry(queued))
        backend.open()
        try await waitUntil { backend.prompts.filter { !$0.hasPrefix(SummaryPrompts.tareasRol) }.count == 2 }
        try await waitUntil { summaryFinished(probe) }

        for dir in [running, queued] {
            #expect(try summaryObject(dir)["title"] as? String == "Nuevo")
            #expect(!exists(SessionFiles.summaryError, dir))
            #expect(!exists(SessionFiles.summaryPending, dir))
            #expect(!exists(SessionFiles.tasksPending, dir))
        }
    }
}

// MARK: - Calendar context

private func linkedEvent() -> CalendarEventRecord {
    CalendarEventRecord(
        snapshot: CalendarFixtures.snapshot(
            title: "Weekly Roadmap",
            organizer: CalendarFixtures.person("Persona Organizadora", email: "organizadora@example.com"),
            attendees: [CalendarFixtures.person("Persona Invitada", email: "invitada@example.com")]),
        matchedAt: CalendarFixtures.at(1))
}

extension SummaryCoordinatorTests {
    @Test func aLinkedEventReachesTheSinglePromptAtJobTime() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        try SessionFiles.setCalendarEvent(linkedEvent(), in: dir)
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        let user = backend.calls[0][1].content
        #expect(user.contains("Weekly Roadmap"))
        #expect(user.contains("Persona Organizadora, Persona Invitada"))
        #expect(user.contains(MinutesPrompts.invitadosAviso))
        #expect(!user.contains("@"))
    }

    @Test func noLinkedEventLeavesTheSinglePromptAsItWas() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = SummaryFakeBackend()
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        #expect(backend.calls[0][1].content.hasPrefix("Sesión: s1\n\nContenido de la reunión:\n"))
        #expect(!backend.calls[0][1].content.contains("Weekly Roadmap"))
        #expect(!backend.calls[0][1].content.contains(MinutesPrompts.invitadosAviso))
    }

    @Test func aLinkedEventReachesTheChunkedPrompts() async throws {
        let fixture = try SessionFixture()
        let dir = try longSummarySession(fixture, lines: 60)
        try SessionFiles.setCalendarEvent(linkedEvent(), in: dir)
        let backend = SummaryFakeBackend(contextLength: 4_000)
        let probe = SummaryProbe()
        let coordinator = await makeSummaryCoordinator(backend: backend, probe: probe)

        await coordinator.request(dir)
        try await waitUntil { summaryFinished(probe) }

        let calls = backend.calls
        #expect(calls.count >= 3)
        for call in calls {
            #expect(call[1].content.contains("Weekly Roadmap"))
            #expect(call[1].content.contains(MinutesPrompts.invitadosAviso))
        }
    }
}

// MARK: - Session folder gone (moved to the Trash)

@Suite struct SummaryMissingFolderTests {
    private func coordinator(
        backend: any MinutesBackend, probe: SummaryProbe, finished: FinishedDirs
    ) async -> SummaryCoordinator {
        let env = SummaryCoordinator.Environment(
            backend: backend, keyStore: SummaryFixedKey(present: true), config: summaryConfig(),
            now: { probe.now }, sleep: { probe.sleep($0) }, notify: { probe.notify($0) },
            timeZone: TimeZone(identifier: "UTC")!, indexDidChange: { probe.indexChanged() },
            didFinish: { finished.append($0) }
        )
        let coordinator = SummaryCoordinator(environment: env)
        await coordinator.setStatusHandler { probe.status($0) }
        return coordinator
    }

    private func failedStatus(_ probe: SummaryProbe) -> Bool {
        probe.statuses.contains { if case .failed = $0 { true } else { false } }
    }

    /// Queued behind a held job, then its folder is trashed: dropped without a
    /// notice, a failure state or a `didFinish`.
    @Test func aQueuedJobWhoseFolderWasTrashedIsDroppedSilently() async throws {
        let fixture = try SessionFixture()
        let first = try summarySession(fixture, "s1")
        let second = try summarySession(fixture, "s2")
        let backend = GatedSummaryBackend()
        let probe = SummaryProbe()
        let finished = FinishedDirs()
        let coordinator = await coordinator(backend: backend, probe: probe, finished: finished)

        await coordinator.request(first)
        try await waitUntil { backend.prompts.count == 1 }
        await coordinator.request(second)
        try FileManager.default.removeItem(at: second)
        backend.open()
        try await waitUntil { summaryFinished(probe) }

        #expect(finished.dirs == [first])
        #expect(probe.notices.isEmpty)
        #expect(!failedStatus(probe))
        #expect(backend.prompts.count == 1)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    /// The folder vanishes while the model call is in flight.
    @Test func aFolderTrashedMidJobIsDroppedSilently() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        let backend = GatedSummaryBackend()
        let probe = SummaryProbe()
        let finished = FinishedDirs()
        let coordinator = await coordinator(backend: backend, probe: probe, finished: finished)

        await coordinator.request(dir)
        try await waitUntil { backend.prompts.count == 1 }
        try FileManager.default.removeItem(at: dir)
        backend.open()
        try await waitUntil { summaryFinished(probe) }

        #expect(finished.dirs.isEmpty)
        #expect(probe.notices.isEmpty)
        #expect(!failedStatus(probe))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func aRetryOfATrashedSessionDoesNothing() async throws {
        let fixture = try SessionFixture()
        let dir = try summarySession(fixture, "s1")
        try FileManager.default.removeItem(at: dir)
        let probe = SummaryProbe()
        let finished = FinishedDirs()
        let coordinator = await coordinator(backend: SummaryFakeBackend(), probe: probe, finished: finished)

        await coordinator.retry(dir)
        try await Task.sleep(for: .milliseconds(150))

        #expect(finished.dirs.isEmpty)
        #expect(probe.notices.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}

