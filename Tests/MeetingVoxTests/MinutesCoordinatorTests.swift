import Foundation
import Testing
@testable import MeetingVox

// MARK: - Fakes

/// Scripted OpenRouter: each `complete` call pops the next result (a default
/// minutes text once the script runs out) and records the messages and the
/// output cap. With `fillOutput`, unscripted answers are as long as the cap
/// allows, like a verbose model.
private final class FakeBackend: MinutesBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<String, OpenRouterError>]
    private var _calls: [[ChatMessage]] = []
    private var _maxTokens: [Int] = []
    private var modelsFailures: Int
    let contextLength: Int?
    let fillOutput: Bool

    init(
        script: [Result<String, OpenRouterError>] = [], contextLength: Int? = 128_000,
        modelsFailures: Int = 0, fillOutput: Bool = false
    ) {
        self.script = script
        self.contextLength = contextLength
        self.modelsFailures = modelsFailures
        self.fillOutput = fillOutput
    }

    var calls: [[ChatMessage]] { lock.withLock { _calls } }
    var maxTokens: [Int] { lock.withLock { _maxTokens } }

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
        let fill = fillOutput
        let next: Result<String, OpenRouterError> = lock.withLock {
            _calls.append(messages)
            _maxTokens.append(maxTokens)
            if !script.isEmpty { return script.removeFirst() }
            // ~3.5 chars per token: "nota " is 5 chars.
            return .success(fill ? String(repeating: "nota ", count: maxTokens * 7 / 10) : "# Minuta\n\ncontenido")
        }
        return try next.get()
    }
}

private struct FixedKey: APIKeyStore {
    func hasAPIKey() -> Bool { true }
    func read() throws -> String? { "sk-test" }
    func save(_ secret: String) throws {}
    func delete() throws {}
}

/// Fake clock + sleeper: sleeping advances time instantly.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    private var _sleeps: [TimeInterval] = []
    private var _hooks: [URL] = []
    private var _notifications: [String] = []
    private var _notificationBodies: [String] = []
    private var _notices: [Notice] = []
    private var _statuses: [MinutesCoordinator.Status] = []
    private var _automaticFinished: [URL] = []
    private var _minutesWritten: [URL] = []
    private var _claims: [URL] = []
    /// "claim" / "notice" in the order they happened: the claim must come
    /// first, or the settlement check could race the notice.
    private var _order: [String] = []
    /// A single ordered log of "hook" / "automaticFinished" events, so tests
    /// can assert the hook always precedes the summary handoff (not just
    /// that both happened).
    private var _events: [String] = []

    var now: Date { lock.withLock { _now } }
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }
    var hooks: [URL] { lock.withLock { _hooks } }
    var notifications: [String] { lock.withLock { _notifications } }
    var notificationBodies: [String] { lock.withLock { _notificationBodies } }
    var notices: [Notice] { lock.withLock { _notices } }
    var statuses: [MinutesCoordinator.Status] { lock.withLock { _statuses } }
    var automaticFinished: [URL] { lock.withLock { _automaticFinished } }
    var minutesWritten: [URL] { lock.withLock { _minutesWritten } }
    var claims: [URL] { lock.withLock { _claims } }
    var order: [String] { lock.withLock { _order } }
    var events: [String] { lock.withLock { _events } }

    func sleep(_ seconds: TimeInterval) {
        lock.withLock {
            _sleeps.append(seconds)
            _now = _now.addingTimeInterval(seconds)
        }
    }
    func hook(_ dir: URL) { lock.withLock { _hooks.append(dir); _events.append("hook:\(dir.lastPathComponent)") } }
    func notify(_ notice: Notice) {
        lock.withLock {
            _notifications.append(notice.title)
            _notificationBodies.append(notice.body)
            _notices.append(notice)
            _order.append("notice")
        }
    }
    func claimReady(_ dir: URL) { lock.withLock { _claims.append(dir); _order.append("claim") } }
    func status(_ s: MinutesCoordinator.Status) { lock.withLock { _statuses.append(s) } }
    func automaticFinished(_ dir: URL) {
        lock.withLock {
            _automaticFinished.append(dir)
            _events.append("automaticFinished:\(dir.lastPathComponent)")
        }
    }
    func minutesWritten(_ dir: URL) {
        lock.withLock {
            _minutesWritten.append(dir)
            _events.append("minutesWritten:\(dir.lastPathComponent)")
        }
    }
}

/// Poll until `condition` holds (the coordinators drain on their own tasks).
func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Fixtures

final class SessionFixture {
    let root: URL
    let templates: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-minutes-\(UUID().uuidString)", isDirectory: true)
        templates = root.appendingPathComponent("plantillas", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try TemplateStore.installFactoryTemplatesIfMissing(in: templates)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A session folder with meta.json, optionally transcript.json and the
    /// pending marker.
    @discardableResult
    func session(_ name: String, transcript: Bool = true, pending: Bool = true, text: String = "Hola") throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"started": "2026-09-23T14:05:00Z", "duration_seconds": 3900, "files": {"mic": "mic.caf"}}"#.utf8)
            .write(to: dir.appendingPathComponent("meta.json"))
        if transcript {
            let json = """
            {"engine": "fake", "model": "fake", "created_at": "2026-09-23T15:10:00Z", "segments": [
              {"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "\(text)"},
              {"speaker": "them", "start_ms": 1500, "end_ms": 2500, "text": "Buenas"}
            ]}
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("transcript.json"))
        }
        if pending { try SessionFiles.writeMarker(SessionFiles.minutesPending, in: dir) }
        return dir
    }
}

private func minutesConfig(enabled: Bool = true, template: String = "general") -> @Sendable () -> ConfigValues {
    {
        ConfigValues(raw: [
            "minutes": ["enabled": enabled, "template": template, "language": "español"],
            "openrouter": ["model": "m/x"],
            "glossary": ["Grafana"],
        ])
    }
}

private func makeCoordinator(
    _ fixture: SessionFixture, backend: FakeBackend, probe: Probe, enabled: Bool = true, template: String = "general",
    writeMinutesFile: (@Sendable (Data, URL) throws -> Void)? = nil
) async -> MinutesCoordinator {
    var env = MinutesCoordinator.Environment(
        backend: backend,
        keyStore: FixedKey(),
        config: minutesConfig(enabled: enabled, template: template),
        templatesDir: fixture.templates,
        now: { probe.now },
        sleep: { probe.sleep($0) },
        notify: { probe.notify($0) },
        launchHook: { _, dir in
            probe.hook(dir)
            return nil
        },
        timeZone: TimeZone(identifier: "UTC")!,
        onAutomaticFinished: { dir in probe.automaticFinished(dir) },
        onMinutesWritten: { dir in probe.minutesWritten(dir) },
        claimReadyNotice: { dir in probe.claimReady(dir) }
    )
    if let writeMinutesFile { env.writeMinutesFile = writeMinutesFile }
    let coordinator = MinutesCoordinator(environment: env)
    await coordinator.setStatusHandler { probe.status($0) }
    return coordinator
}

/// Done = the drain loop published its final idle/failed status.
private func finished(_ probe: Probe, runs: Int = 1) -> Bool {
    probe.statuses.filter {
        switch $0 {
        case .idle, .failed: true
        default: false
        }
    }.count >= runs
}

private func exists(_ name: String, _ dir: URL) -> Bool { SessionFiles.exists(name, in: dir) }

/// A pending session with `lines` alternating-speaker lines of ~200 chars
/// (alternating so no lines merge).
private func longSession(_ fixture: SessionFixture, lines: Int) throws -> URL {
    let dir = fixture.root.appendingPathComponent("largo", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"duration_seconds": 600}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
    let segments = (0..<lines).map { i in
        #"{"speaker": "\#(i % 2 == 0 ? "me" : "them")", "start_ms": \#(i * 10_000), "end_ms": \#(i * 10_000 + 9_000), "text": "\#(String(repeating: "palabra ", count: 25))"}"#
    }
    try Data(#"{"segments": [\#(segments.joined(separator: ","))]}"#.utf8)
        .write(to: dir.appendingPathComponent("transcript.json"))
    try SessionFiles.writeMarker(SessionFiles.minutesPending, in: dir)
    return dir
}

// MARK: - MinutesCoordinator

@Suite struct MinutesCoordinatorTests {
    @Test func automaticSuccessWritesMinutesRemovesMarkerRunsHookOnce() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405")
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        let minutes = try String(contentsOf: dir.appendingPathComponent("minuta.md"), encoding: .utf8)
        let firstLine = try #require(minutes.components(separatedBy: "\n").first)
        #expect(firstLine.hasPrefix("<!-- quill minutes"))
        #expect(firstLine.contains("model: m/x"))
        #expect(firstLine.contains("template: general"))
        #expect(firstLine.contains("generated_at: 2027-01-15T08:00:00Z"))
        #expect(firstLine.contains("chunked: no"))
        #expect(minutes.contains("# Minuta\n\ncontenido"))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(!exists(SessionFiles.minutesError, dir))
        #expect(probe.hooks == [dir])
        // The automatic path posts no per-stage success notice; the
        // single "reunión lista" comes from the settlement notifier.
        #expect(probe.notices.isEmpty)
        #expect(probe.statuses.last == .idle)

        // One call; the transcript went out as text with the glossary.
        let calls = backend.calls
        #expect(calls.count == 1)
        #expect(calls[0][0].role == "system")
        #expect(calls[0][0].content.contains("Grafana"))
        #expect(calls[0][1].content.contains("[00:00] Yo: Hola\n[00:01] Otros: Buenas"))

        let log = try String(contentsOf: dir.appendingPathComponent("minuta.log"), encoding: .utf8)
        #expect(log.contains("model m/x, template general"))
        #expect(!log.contains("sk-test"))
    }

    @Test func nonRetryableFailureMarksErrorAndRunsHookOnce() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        let backend = FakeBackend(script: [.failure(.unauthorized("bad key"))])
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        #expect(backend.calls.count == 1)
        #expect(probe.sleeps.isEmpty)
        #expect(!exists("minuta.md", dir))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(exists(SessionFiles.minutesError, dir))
        #expect(probe.hooks == [dir])
        #expect(probe.notifications == [Textos.Notificacion.minutaFallida])
        // Says what failed, never sends the user to minuta.log.
        #expect(probe.notices.map(\.kind) == [.failure(.minutes, retryable: true)])
        #expect(probe.notices.first?.session == dir)
        #expect(probe.notificationBodies == [Textos.Notificacion.minutaFallidaCuerpo("s1")])
        #expect(probe.notificationBodies.allSatisfy { !$0.contains("revisa") && !$0.contains(".log") })
        #expect(probe.statuses.last == .failed(session: "s1"))
    }

    @Test func retryableThenSuccessUsesInjectedClock() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        let backend = FakeBackend(script: [
            .failure(.server(status: 503, message: nil)),
            .failure(.transport("offline")),
        ])
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.sleeps == [30, 120])
        #expect(backend.calls.count == 3)
        #expect(exists("minuta.md", dir))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(probe.hooks == [dir])
        #expect(probe.statuses.contains(.waitingRetry(session: "s1")))
    }

    @Test func retriesExhaustedKeepPendingWithoutHook() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        let backend = FakeBackend(script: Array(repeating: .failure(.transport("offline")), count: 4))
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.sleeps == [30, 120, 600])
        #expect(backend.calls.count == 4)
        // Still owed: resumed at next launch, no error marker, no hook yet.
        #expect(exists(SessionFiles.minutesPending, dir))
        #expect(!exists(SessionFiles.minutesError, dir))
        #expect(!exists(SessionFiles.hookRan, dir))
        #expect(probe.hooks.isEmpty)
        #expect(probe.notifications == [Textos.Notificacion.minutaFallida])
        // Existing "still pending" copy stays truthful.
        #expect(probe.notificationBodies == [Textos.Notificacion.minutaSigue("s1")])
        #expect(probe.notices.map(\.kind) == [.failure(.minutes, retryable: true)])
        #expect(probe.statuses.last == .failed(session: "s1"))

        // "Reintentar minuta" once back online: minuta.md, markers gone, hook once.
        await coordinator.retry(dir)
        try await waitUntil { finished(probe, runs: 2) }
        #expect(exists("minuta.md", dir))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(probe.hooks == [dir])
        #expect(exists(SessionFiles.hookRan, dir))
    }

    @Test func onAutomaticFinishedCalledAfterHookOnSuccess() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.automaticFinished == [dir])
        #expect(probe.hooks == [dir])
        #expect(probe.events == ["hook:s1", "automaticFinished:s1", "minutesWritten:s1"])
    }

    @Test func onAutomaticFinishedCalledAfterHookOnNonRetryableFailure() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        let backend = FakeBackend(script: [.failure(.unauthorized("bad key"))])
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.automaticFinished == [dir])
        #expect(probe.events == ["hook:s1", "automaticFinished:s1"])
    }

    @Test func onAutomaticFinishedNotCalledWhenRetriesExhausted() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        let backend = FakeBackend(script: Array(repeating: .failure(.transport("offline")), count: 4))
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.automaticFinished.isEmpty)
    }

    @Test func onAutomaticFinishedNotCalledForManualJobs() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generate(dir, templateID: "daily")
        try await waitUntil { finished(probe) }

        #expect(probe.automaticFinished.isEmpty)
    }

    @Test func onAutomaticFinishedCalledOnDisabledResume() async throws {
        let fixture = try SessionFixture()
        let marked = try fixture.session("2026.09.20-1000")
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe, enabled: false)

        await coordinator.resumePending(root: fixture.root)

        #expect(probe.automaticFinished.map(\.lastPathComponent) == [marked.lastPathComponent])
    }

    @Test func retryFromMenuRecoversFailedSession() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try SessionFiles.writeMarker(SessionFiles.minutesError, in: dir)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.retry(dir)
        try await waitUntil { finished(probe) }

        #expect(exists("minuta.md", dir))
        #expect(!exists(SessionFiles.minutesError, dir))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(probe.hooks == [dir])
    }

    @Test func hookRunsOncePerSessionAcrossRuns() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }
        #expect(exists(SessionFiles.hookRan, dir))

        // A second automatic run (e.g. a stuck marker resumed at launch).
        try SessionFiles.writeMarker(SessionFiles.minutesPending, in: dir)
        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe, runs: 2) }

        #expect(backend.calls.count == 2)
        #expect(probe.hooks == [dir])
        let log = try String(contentsOf: dir.appendingPathComponent("minuta.log"), encoding: .utf8)
        #expect(log.contains("on_stop hook already ran for this session; skipping"))
    }

    // MARK: - generateFromWindow (main window "Generar minuta")

    @Test func generateFromWindowSuccessWritesMinutesNeverRunsHookAndCallsSummarySeam() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generateFromWindow(dir)
        try await waitUntil { finished(probe) }

        #expect(exists("minuta.md", dir))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(!exists(SessionFiles.minutesError, dir))
        #expect(!exists(SessionFiles.hookRan, dir))
        #expect(probe.hooks.isEmpty)
        #expect(probe.automaticFinished == [dir])
        #expect(probe.minutesWritten == [dir])
    }

    @Test func generateFromWindowFailureNeverRunsHookOrWritesErrorMarker() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let backend = FakeBackend(script: [.failure(.unauthorized("bad key"))])
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generateFromWindow(dir)
        try await waitUntil { finished(probe) }

        #expect(!exists("minuta.md", dir))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(!exists(SessionFiles.minutesError, dir))
        #expect(!exists(SessionFiles.hookRan, dir))
        #expect(probe.hooks.isEmpty)
        #expect(probe.automaticFinished.isEmpty)
        #expect(probe.notifications == [Textos.Notificacion.minutaFallida])
        let log = try String(contentsOf: dir.appendingPathComponent("minuta.log"), encoding: .utf8)
        #expect(log.contains("minutes failed"))
    }

    @Test func generateFromWindowSkipsWhenMinutesAlreadyExist() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try Data("# Minuta existente".utf8).write(to: dir.appendingPathComponent("minuta.md"))
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generateFromWindow(dir)
        try await Task.sleep(for: .milliseconds(50))

        #expect(backend.calls.isEmpty)
        #expect(probe.automaticFinished.isEmpty)
    }

    @Test func generateFromWindowSkipsWhenAnAutomaticJobIsAlreadyPendingOrQueued() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1") // pending: true → an automatic job runs
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        await coordinator.generateFromWindow(dir)
        try await waitUntil { finished(probe) }

        // Only the automatic job ran — no duplicate, no second attempt.
        #expect(backend.calls.count == 1)
        #expect(probe.hooks == [dir])
        #expect(probe.automaticFinished == [dir])
    }

    @Test func generateFromWindowSkipsWhenMinutesPendingMarkerExistsOnDisk() async throws {
        let fixture = try SessionFixture()
        // A pending marker with no in-flight job (e.g. left over after a
        // crash, or from a stale automatic run) — the window must not start
        // a duplicate userRequested job over it.
        let dir = try fixture.session("s1", pending: true)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generateFromWindow(dir)
        try await Task.sleep(for: .milliseconds(50))

        #expect(backend.calls.isEmpty)
        #expect(probe.automaticFinished.isEmpty)
    }

    @Test func generateFromWindowSkipsWhenMinutesErrorMarkerExistsOnDisk() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try SessionFiles.writeMarker(SessionFiles.minutesError, in: dir)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generateFromWindow(dir)
        try await Task.sleep(for: .milliseconds(50))

        #expect(backend.calls.isEmpty)
        #expect(probe.automaticFinished.isEmpty)
    }

    @Test func generateFromWindowRetryableThenSuccessNeverWritesMarkersOrRunsHookAndCallsSummarySeamOnce() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let backend = FakeBackend(script: [.failure(.server(status: 503, message: nil))])
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generateFromWindow(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.sleeps == [30])
        #expect(backend.calls.count == 2)
        #expect(exists("minuta.md", dir))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(!exists(SessionFiles.minutesError, dir))
        #expect(!exists(SessionFiles.hookRan, dir))
        #expect(probe.hooks.isEmpty)
        #expect(probe.automaticFinished == [dir])
        #expect(probe.notifications == [Textos.Notificacion.minutaLista])
        #expect(probe.notices.map(\.kind) == [.minutesReady(file: "minuta.md")])
    }

    @Test func generateFromWindowRetriesExhaustedWritesNoMarkerNeverRunsHookSkipsSummarySeamAndUsesWindowSpecificNotification() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let backend = FakeBackend(script: Array(repeating: .failure(.transport("offline")), count: 4))
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generateFromWindow(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.sleeps == [30, 120, 600])
        #expect(backend.calls.count == 4)
        // Never resumed at launch, never surfaced by "Reintentar minuta":
        // no marker is ever written for a userRequested job.
        #expect(!exists("minuta.md", dir))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(!exists(SessionFiles.minutesError, dir))
        #expect(!exists(SessionFiles.hookRan, dir))
        #expect(probe.hooks.isEmpty)
        #expect(probe.automaticFinished.isEmpty)
        #expect(probe.notifications == [Textos.Notificacion.minutaFallida])
        #expect(probe.notificationBodies == [Textos.Notificacion.minutaNoGeneradaDesdeVentana("s1")])
    }

    // MARK: - One "ready" per meeting: a user-requested notice takes the claim first

    @Test func aUserRequestedSuccessClaimsTheReadyNoticeBeforePostingItsOwn() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: FakeBackend(), probe: probe)

        await coordinator.generateFromWindow(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.claims == [dir])
        #expect(probe.order == ["claim", "notice"])
    }

    @Test func aRegenerateSuccessClaimsTheReadyNoticeBeforePostingItsOwn() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try writeCurrentMinutes(dir)
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: FakeBackend(), probe: probe)

        await coordinator.regenerate(dir, templateID: "daily")
        try await waitUntil { finished(probe) }

        #expect(probe.claims == [dir])
        #expect(probe.order == ["claim", "notice"])
    }

    /// Manual "Generar minuta con..." writes an extra `minuta.<id>.md` and never
    /// triggers settlement: it must not silence the pipeline's own ready notice.
    @Test func aManualSuccessNeverClaimsTheReadyNotice() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: FakeBackend(), probe: probe)

        await coordinator.generate(dir, templateID: "daily")
        try await waitUntil { finished(probe) }

        #expect(probe.notices.map(\.kind) == [.minutesReady(file: "minuta.daily.md")])
        #expect(probe.claims.isEmpty)
        #expect(probe.order == ["notice"])
    }

    @Test func anAutomaticSuccessNeverClaimsBecauseTheSettlementCheckOwnsItsNotice() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: FakeBackend(), probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        #expect(exists("minuta.md", dir))
        #expect(probe.claims.isEmpty)
        #expect(probe.order.isEmpty)
    }

    @Test func aFailedUserRequestedJobNeitherClaimsNorThereforeSilencesALaterReadyNotice() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let backend = FakeBackend(script: [.failure(.unauthorized("bad key"))])
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generateFromWindow(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.notices.map(\.kind) == [.failure(.minutes, retryable: true)])
        #expect(probe.claims.isEmpty)
    }

    @Test func manualWritesTemplateFileWithoutHook() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generate(dir, templateID: "daily")
        try await waitUntil { finished(probe) }

        let text = try String(contentsOf: dir.appendingPathComponent("minuta.daily.md"), encoding: .utf8)
        #expect(text.contains("template: daily"))
        #expect(!exists("minuta.md", dir))
        #expect(!exists(SessionFiles.minutesError, dir))
        #expect(probe.hooks.isEmpty)
        #expect(backend.calls[0][0].content.contains(FactoryTemplates.daily.cuerpo))
        #expect(probe.minutesWritten.isEmpty)
        // A user-initiated success keeps its "Minuta lista" with the file to open.
        #expect(probe.notifications == [Textos.Notificacion.minutaLista])
        #expect(probe.notices.map(\.kind) == [.minutesReady(file: "minuta.daily.md")])
        #expect(probe.notices.first?.session == dir)
    }

    @Test func manualMissingTemplateFailsWithNotification() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generate(dir, templateID: "no-existe")
        try await waitUntil { finished(probe) }

        #expect(backend.calls.isEmpty)
        #expect(!exists("minuta.general.md", dir))
        #expect(!exists(SessionFiles.minutesError, dir))
        #expect(probe.hooks.isEmpty)
        #expect(probe.notifications == [Textos.Notificacion.minutaFallida])
        let log = try String(contentsOf: dir.appendingPathComponent("minuta.log"), encoding: .utf8)
        #expect(log.contains("template \"no-existe\" not found or invalid"))
    }

    @Test func manualInvalidTemplateIdFails() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        // A readable .md outside the templates folder must not be reachable.
        try Data("---\nnombre: X\n---\nsecreto".utf8).write(to: fixture.root.appendingPathComponent("fuera.md"))
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.generate(dir, templateID: "../fuera")
        try await waitUntil { finished(probe) }

        #expect(backend.calls.isEmpty)
        #expect(probe.notifications == [Textos.Notificacion.minutaFallida])
    }

    @Test(arguments: ["no-existe", "../fuera", ".oculta", "a/b"])
    func automaticBadConfigTemplateFallsBackToGeneral(_ id: String) async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        try Data("---\nnombre: X\n---\nsecreto".utf8).write(to: fixture.root.appendingPathComponent("fuera.md"))
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe, template: id)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        let text = try String(contentsOf: dir.appendingPathComponent("minuta.md"), encoding: .utf8)
        #expect(text.contains("template: general"))
        #expect(!(backend.calls.first?[0].content.contains("secreto") ?? true))
        let log = try String(contentsOf: dir.appendingPathComponent("minuta.log"), encoding: .utf8)
        #expect(log.contains("template \"\(id)\""))
        #expect(log.contains("using \"general\""))
    }

    @Test func longTranscriptIsChunkedThenConsolidated() async throws {
        let fixture = try SessionFixture()
        // ~3.5k tokens of transcript vs a 4k context → chunk at 1.6k tokens.
        let dir = try longSession(fixture, lines: 60)
        let backend = FakeBackend(contextLength: 4_000)
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        let calls = backend.calls
        #expect(calls.count >= 3)
        let partials = calls.dropLast()
        for (i, call) in partials.enumerated() {
            #expect(call[0].content.contains("parte \(i + 1) de \(partials.count)"))
        }
        #expect(calls.last?[1].content.contains(MinutesPrompts.introConsolidacion) == true)
        // Each note is capped below the full output cap so all of them fit.
        for cap in backend.maxTokens.dropLast() {
            #expect(cap <= Chunker.maxTokens(contextLength: 4_000))
        }
        let text = try String(contentsOf: dir.appendingPathComponent("minuta.md"), encoding: .utf8)
        #expect(text.contains("chunked: yes"))
    }

    @Test func oversizeConsolidationIsReducedHierarchically() async throws {
        let fixture = try SessionFixture()
        // ~11k tokens at a 4k context: 7+ chunks, whose notes (filled to
        // their cap, floored at 256) can't all fit one consolidation prompt.
        let dir = try longSession(fixture, lines: 200)
        let backend = FakeBackend(contextLength: 4_000, fillOutput: true)
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        let calls = backend.calls
        #expect(calls.contains { $0[0].content.hasPrefix(MinutesPrompts.rolReduccion) })
        let final = try #require(calls.last)
        #expect(final[1].content.contains(MinutesPrompts.introConsolidacion))
        let size = Chunker.estimateTokens(final[0].content) + Chunker.estimateTokens(final[1].content)
        #expect(size <= Chunker.promptBudget(contextLength: 4_000))
        for (call, cap) in zip(calls, backend.maxTokens) {
            let prompt = call.map { Chunker.estimateTokens($0.content) }.reduce(0, +)
            #expect(prompt + cap <= 4_000)
        }
        #expect(exists("minuta.md", dir))
        let log = try String(contentsOf: dir.appendingPathComponent("minuta.log"), encoding: .utf8)
        #expect(log.contains("condensing"))
    }

    @Test func partialNotesFromAnotherSplitAreDiscarded() async throws {
        let fixture = try SessionFixture()
        // ~25k tokens: chunked at the 32k fallback (catalog down on attempt
        // 1) and differently at the real 4k context on attempt 2.
        let dir = try longSession(fixture, lines: 400)
        let backend = FakeBackend(
            script: [.success("nota 1"), .failure(.server(status: 503, message: nil))],
            contextLength: 4_000, modelsFailures: 1
        )
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        let calls = backend.calls
        #expect(calls[0][0].content.contains("parte 1 de 2"))
        // Attempt 2 starts over at part 1 of the new split.
        #expect(!calls[2][0].content.contains("de 2,"))
        #expect(calls[2][0].content.contains("parte 1 de"))
        #expect(!calls.contains { $0.contains { $0.content.contains("nota 1") } })
        let log = try String(contentsOf: dir.appendingPathComponent("minuta.log"), encoding: .utf8)
        #expect(log.contains("chunk split changed since the last attempt; discarding 1 partial note(s)"))
    }

    @Test func recoveryPicksOnlyMarkedSessions() async throws {
        let fixture = try SessionFixture()
        let marked = try fixture.session("2026.09.20-1000")
        let unmarked = try fixture.session("2026.09.21-1000", pending: false)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.resumePending(root: fixture.root)
        try await waitUntil { finished(probe) }

        #expect(exists("minuta.md", marked))
        #expect(!exists("minuta.md", unmarked))
        #expect(backend.calls.count == 1)
        // The scan resolves /var → /private/var; compare folder names.
        #expect(probe.hooks.map(\.lastPathComponent) == [marked.lastPathComponent])
    }

    @Test func recoveryWithMinutesDisabledDropsMarkerAndRunsHookOnce() async throws {
        let fixture = try SessionFixture()
        let marked = try fixture.session("2026.09.20-1000")
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe, enabled: false)

        await coordinator.resumePending(root: fixture.root)
        await coordinator.resumePending(root: fixture.root)

        #expect(!exists(SessionFiles.minutesPending, marked))
        #expect(exists(SessionFiles.hookRan, marked))
        #expect(probe.hooks.map(\.lastPathComponent) == [marked.lastPathComponent])
        #expect(backend.calls.isEmpty)
        #expect(probe.statuses.isEmpty)
        let log = try String(contentsOf: marked.appendingPathComponent("minuta.log"), encoding: .utf8)
        #expect(log.contains("minutes disabled; skipping"))
    }

    /// meta.json as RecordingSession writes it when a template was chosen.
    private func chooseTemplate(_ id: String, for dir: URL) throws {
        let url = dir.appendingPathComponent("meta.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["minutes_template"] = id
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    @Test func automaticUsesTemplateChosenForTheSession() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        try chooseTemplate("daily", for: dir)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe, template: "comercial")

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        let text = try String(contentsOf: dir.appendingPathComponent("minuta.md"), encoding: .utf8)
        #expect(text.contains("template: daily"))
        let log = try String(contentsOf: dir.appendingPathComponent("minuta.log"), encoding: .utf8)
        #expect(log.contains("template \"daily\" from meta.json"))
    }

    @Test func automaticWithoutSessionTemplateLogsConfigDefault() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: FakeBackend(), probe: probe, template: "comercial")

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        let text = try String(contentsOf: dir.appendingPathComponent("minuta.md"), encoding: .utf8)
        #expect(text.contains("template: comercial"))
        let log = try String(contentsOf: dir.appendingPathComponent("minuta.log"), encoding: .utf8)
        #expect(log.contains("template \"comercial\" from config"))
        #expect(!log.contains("meta.json"))
    }

    @Test(arguments: ["no-existe", "../fuera", ".oculta"])
    func automaticBadSessionTemplateFallsBackToConfig(_ id: String) async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        try chooseTemplate(id, for: dir)
        try Data("---\nnombre: X\n---\nsecreto".utf8).write(to: fixture.root.appendingPathComponent("fuera.md"))
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe, template: "comercial")

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        let text = try String(contentsOf: dir.appendingPathComponent("minuta.md"), encoding: .utf8)
        #expect(text.contains("template: comercial"))
        #expect(!(backend.calls.first?[0].content.contains("secreto") ?? true))
        let log = try String(contentsOf: dir.appendingPathComponent("minuta.log"), encoding: .utf8)
        #expect(log.contains("session template \"\(id)\" from meta.json"))
        #expect(log.contains("using the config default"))
    }

    // MARK: - Regenerate

    private func writeCurrentMinutes(_ dir: URL, _ text: String = "vieja") throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes))
    }

    private func read(_ name: String, _ dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func regenerateKeepsPreviousWritesNewAndRecordsTemplate() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try writeCurrentMinutes(dir)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.regenerate(dir, templateID: "daily")
        try await waitUntil { finished(probe) }

        #expect(try read(SessionFiles.minutesPrevious, dir) == "vieja")
        let minutes = try read(SessionFiles.minutes, dir)
        #expect(minutes.contains("template: daily"))
        #expect(minutes.contains("# Minuta\n\ncontenido"))
        #expect(SessionFiles.chosenMinutesTemplate(in: dir) == "daily")
        let meta = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json"))) as? [String: Any])
        #expect(meta["duration_seconds"] as? Int == 3900)
        #expect(meta["started"] as? String == "2026-09-23T14:05:00Z")
        #expect(backend.calls[0][0].content.contains(FactoryTemplates.daily.cuerpo))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(!exists(SessionFiles.hookRan, dir))
        #expect(probe.hooks.isEmpty)
        #expect(probe.automaticFinished == [dir])
        #expect(probe.notifications == [Textos.Notificacion.minutaLista])
        #expect(probe.notices.map(\.kind) == [.minutesReady(file: "minuta.md")])
    }

    /// After a regenerate succeeds, an open Reuniones window must refresh
    /// (its Tipo/row can otherwise stay stale — `onAutomaticFinished`'s
    /// summary follow-up usually no-ops once `resumen.json` already exists).
    @Test func regenerateSuccessFiresOnMinutesWrittenSeam() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try writeCurrentMinutes(dir)
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: FakeBackend(), probe: probe)

        await coordinator.regenerate(dir, templateID: "daily")
        try await waitUntil { finished(probe) }

        #expect(probe.minutesWritten == [dir])
    }

    @Test func regenerateOverwritesAnOlderPreviousMinutes() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try writeCurrentMinutes(dir, "vieja")
        try Data("muy vieja".utf8).write(to: dir.appendingPathComponent(SessionFiles.minutesPrevious))
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: FakeBackend(), probe: probe)

        await coordinator.regenerate(dir, templateID: "general")
        try await waitUntil { finished(probe) }

        #expect(try read(SessionFiles.minutesPrevious, dir) == "vieja")
    }

    @Test func regenerateFailureLeavesEverythingAsItWas() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try writeCurrentMinutes(dir, "vieja")
        try Data("muy vieja".utf8).write(to: dir.appendingPathComponent(SessionFiles.minutesPrevious))
        let metaBefore = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        let backend = FakeBackend(script: [.failure(.outputTruncated)])
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.regenerate(dir, templateID: "daily")
        try await waitUntil { finished(probe) }

        #expect(try read(SessionFiles.minutes, dir) == "vieja")
        #expect(try read(SessionFiles.minutesPrevious, dir) == "muy vieja")
        #expect(try Data(contentsOf: dir.appendingPathComponent("meta.json")) == metaBefore)
        #expect(!exists(SessionFiles.minutesError, dir))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(probe.hooks.isEmpty)
        #expect(probe.automaticFinished.isEmpty)
        #expect(probe.notifications == [Textos.Notificacion.minutaFallida])
        #expect(probe.minutesWritten.isEmpty)
    }

    @Test func regenerateExhaustedRetriesUsesItsOwnNotification() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try writeCurrentMinutes(dir)
        let offline = Result<String, OpenRouterError>.failure(.transport("offline"))
        let backend = FakeBackend(script: [offline, offline, offline, offline])
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.regenerate(dir, templateID: "general")
        try await waitUntil { finished(probe) }

        #expect(try read(SessionFiles.minutes, dir) == "vieja")
        #expect(probe.notificationBodies == [Textos.Notificacion.minutaNoRegenerada("s1")])
        #expect(!exists(SessionFiles.minutesPending, dir))
    }

    @Test func regenerateWithoutMinutesIsANoOp() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.regenerate(dir, templateID: "daily")

        #expect(backend.calls.isEmpty)
        #expect(!exists(SessionFiles.minutes, dir))
        let log = try read(SessionFiles.minutesLog, dir)
        #expect(log.contains("regenerate: no minuta.md"))
    }

    @Test func regenerateWithAMissingTemplateFailsAndKeepsTheMinutes() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try writeCurrentMinutes(dir)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.regenerate(dir, templateID: "no-existe")
        try await waitUntil { finished(probe) }

        #expect(backend.calls.isEmpty)
        #expect(try read(SessionFiles.minutes, dir) == "vieja")
        #expect(!exists(SessionFiles.minutesPrevious, dir))
        #expect(probe.notifications == [Textos.Notificacion.minutaFallida])
    }

    @Test func previousMinutesFileIsNotAManualMinutesFile() {
        #expect(SessionFiles.templateID(ofMinutesFile: SessionFiles.minutesPrevious) == nil)
    }

    /// The LLM call succeeds (generation is fine), but writing the result to
    /// disk fails (disk full, permissions, …) — the staging-file ordering in
    /// `replaceMinutes` must leave both `minuta.md` and `minuta-anterior.md`
    /// exactly as they were, with no leftover staging file.
    @Test func regenerateWriteFailureLeavesEverythingAsItWas() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try writeCurrentMinutes(dir, "vieja")
        try Data("muy vieja".utf8).write(to: dir.appendingPathComponent(SessionFiles.minutesPrevious))
        let metaBefore = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(
            fixture, backend: backend, probe: probe,
            writeMinutesFile: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )

        await coordinator.regenerate(dir, templateID: "daily")
        try await waitUntil { finished(probe) }

        #expect(try read(SessionFiles.minutes, dir) == "vieja")
        #expect(try read(SessionFiles.minutesPrevious, dir) == "muy vieja")
        #expect(try Data(contentsOf: dir.appendingPathComponent("meta.json")) == metaBefore)
        #expect(!exists(SessionFiles.minutesError, dir))
        #expect(!exists(SessionFiles.minutesPending, dir))
        #expect(probe.hooks.isEmpty)
        #expect(probe.automaticFinished.isEmpty)
        #expect(probe.notifications == [Textos.Notificacion.minutaFallida])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.contains("regenerating") })
    }
}

// MARK: - generateFromWindow reports whether it took the job

@Suite struct MinutesGenerateFromWindowAcceptanceTests {
    private func coordinator(_ fixture: SessionFixture) async -> MinutesCoordinator {
        await makeCoordinator(fixture, backend: FakeBackend(), probe: Probe())
    }

    @Test func aJobItQueuesIsAccepted() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        let accepted = await coordinator(fixture).generateFromWindow(dir)
        #expect(accepted)
    }

    @Test func minutesAlreadyThereAreRefused() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false)
        try Data("# ya".utf8).write(to: dir.appendingPathComponent("minuta.md"))
        let accepted = await coordinator(fixture).generateFromWindow(dir)
        #expect(!accepted)
    }

    @Test func aPendingOrErrorMarkerIsRefused() async throws {
        let pendingFixture = try SessionFixture()
        let pendingDir = try pendingFixture.session("s1", pending: true)
        let pending = await coordinator(pendingFixture).generateFromWindow(pendingDir)
        #expect(!pending)

        let errorFixture = try SessionFixture()
        let errorDir = try errorFixture.session("s1", pending: false)
        try SessionFiles.writeMarker(SessionFiles.minutesError, in: errorDir)
        let failed = await coordinator(errorFixture).generateFromWindow(errorDir)
        #expect(!failed)
    }

    @Test func anAutomaticJobAlreadyInFlightIsRefused() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1")
        let coordinator = await coordinator(fixture)
        await coordinator.enqueueAutomatic(dir)
        let accepted = await coordinator.generateFromWindow(dir)
        #expect(!accepted)
    }
}

// MARK: - Calendar context

extension MinutesCoordinatorTests {
    private func linkedEvent() -> CalendarEventRecord {
        CalendarEventRecord(
            snapshot: CalendarFixtures.snapshot(
                title: "Weekly Roadmap",
                organizer: CalendarFixtures.person("Persona Organizadora", email: "organizadora@example.com"),
                attendees: [CalendarFixtures.person("Persona Invitada", email: "invitada@example.com")]),
            matchedAt: CalendarFixtures.at(1))
    }

    @Test func aLinkedEventReachesTheMinutesPromptAtJobTime() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405")
        try SessionFiles.setCalendarEvent(linkedEvent(), in: dir)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        let user = backend.calls[0][1].content
        #expect(user.contains("Weekly Roadmap"))
        #expect(user.contains("Persona Organizadora, Persona Invitada"))
        #expect(user.contains(MinutesPrompts.invitadosAviso))
        #expect(!user.contains("@"))
    }

    @Test func aLinkedEventReachesEveryChunkedMinutesCall() async throws {
        let fixture = try SessionFixture()
        let dir = try longSession(fixture, lines: 60)
        try SessionFiles.setCalendarEvent(linkedEvent(), in: dir)
        let backend = FakeBackend(contextLength: 4_000)
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        let calls = backend.calls
        #expect(calls.count >= 3)
        for call in calls { #expect(call[1].content.contains("Weekly Roadmap")) }
    }

    @Test func withoutAnEventTheMinutesPromptHasNoCalendarRows() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405")
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        let user = backend.calls[0][1].content
        #expect(!user.contains(MinutesPrompts.invitadosAviso))
        #expect(!user.contains("Evento del calendario"))
    }

    // MARK: - Session folder gone (moved to the Trash)

    /// A pending automatic job whose folder was trashed before it ran is
    /// dropped silently: no failure notice, no `lastFailure`, no hook, no
    /// follow-ups, and the folder is not recreated.
    @Test func aJobWhoseFolderWasTrashedIsDroppedSilently() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405")
        try FileManager.default.removeItem(at: dir)
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: backend, probe: probe)

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.notices.isEmpty)
        #expect(probe.hooks.isEmpty)
        #expect(probe.automaticFinished.isEmpty)
        #expect(probe.minutesWritten.isEmpty)
        #expect(backend.calls.isEmpty)
        #expect(!probe.statuses.contains { if case .failed = $0 { true } else { false } })
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func aRetryOfATrashedSessionIsDroppedSilently() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405")
        try FileManager.default.removeItem(at: dir)
        let probe = Probe()
        let coordinator = await makeCoordinator(fixture, backend: FakeBackend(), probe: probe)

        await coordinator.retry(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.notices.isEmpty)
        #expect(probe.hooks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// The folder vanishes while the model call is in flight: the failed
    /// write must not turn into a failure notice or the `on_stop` hook.
    @Test func aFolderTrashedMidJobIsDroppedSilently() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405")
        let backend = FakeBackend()
        let probe = Probe()
        let coordinator = await makeCoordinator(
            fixture, backend: backend, probe: probe,
            writeMinutesFile: { _, _ in
                try FileManager.default.removeItem(at: dir)
                throw CocoaError(.fileNoSuchFile)
            }
        )

        await coordinator.enqueueAutomatic(dir)
        try await waitUntil { finished(probe) }

        #expect(probe.notices.isEmpty)
        #expect(probe.hooks.isEmpty)
        #expect(probe.automaticFinished.isEmpty)
    }
}

