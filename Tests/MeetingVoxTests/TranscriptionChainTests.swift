import Foundation
import Testing
@testable import MeetingVox

/// Stands in for Parakeet: one fixed segment per track, no model.
private struct FakeEngine: TranscriptionEngine {
    let name = "fake"
    let model = "fake-1"
    var text = "hola"
    func prepare() async throws {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        [TranscriptSegment(start: 0, end: 1, text: text)]
    }
    func release() async {}
}

private final class ChainProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _handoffs: [URL] = []
    private var _summaryHandoffs: [URL] = []
    private var _hooks: [URL] = []
    private var _done = false
    private var _notices: [Notice] = []

    var notices: [Notice] { lock.withLock { _notices } }
    var handoffs: [URL] { lock.withLock { _handoffs } }
    var summaryHandoffs: [URL] { lock.withLock { _summaryHandoffs } }
    var hooks: [URL] { lock.withLock { _hooks } }
    var done: Bool { lock.withLock { _done } }

    func handoff(_ dir: URL) { lock.withLock { _handoffs.append(dir) } }
    func summaryHandoff(_ dir: URL) { lock.withLock { _summaryHandoffs.append(dir) } }
    func hook(_ dir: URL) { lock.withLock { _hooks.append(dir) } }
    func notify(_ notice: Notice) { lock.withLock { _notices.append(notice) } }
    func status(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle, .failed: lock.withLock { _done = true }
        case .transcribing: break
        }
    }
}

/// The transcription → minutes chain, with a fake engine instead of the
/// real model (only the empty `mic.caf` file has to exist).
@Suite struct TranscriptionChainTests {
    private func run(
        _ fixture: SessionFixture, minutesEnabled: Bool, transcriptionEnabled: Bool = true,
        withHandoff: Bool = true, hookAlreadyRan: Bool = false, brokenMeta: Bool = false
    ) async throws -> (URL, ChainProbe) {
        let dir = try fixture.session("s1", transcript: false, pending: false)
        try Data().write(to: dir.appendingPathComponent("mic.caf"))
        if brokenMeta { try Data("{}".utf8).write(to: dir.appendingPathComponent(SessionFiles.meta)) }
        if hookAlreadyRan { try SessionFiles.writeMarker(SessionFiles.hookRan, in: dir) }

        let probe = ChainProbe()
        var handoff: (@Sendable (URL) async -> Void)?
        if withHandoff { handoff = { @Sendable dir in probe.handoff(dir) } }
        let coordinator = TranscriptionCoordinator(
            config: {
                ConfigValues(raw: [
                    "minutes": ["enabled": minutesEnabled],
                    "transcription": ["enabled": transcriptionEnabled],
                ])
            },
            makeEngine: { FakeEngine() },
            minutesHandoff: handoff,
            summaryHandoff: { @Sendable dir in probe.summaryHandoff(dir) },
            hook: { probe.hook($0) },
            notify: { probe.notify($0) }
        )
        await coordinator.setStatusHandler { probe.status($0) }
        await coordinator.enqueue(dir)
        if transcriptionEnabled { try await waitUntil { probe.done } }
        return (dir, probe)
    }

    @Test func minutesEnabledDefersHookAndWritesMarker() async throws {
        let fixture = try SessionFixture()
        let (dir, probe) = try await run(fixture, minutesEnabled: true)
        #expect(SessionFiles.exists(SessionFiles.transcriptJSON, in: dir))
        #expect(SessionFiles.exists(SessionFiles.minutesPending, in: dir))
        #expect(probe.handoffs == [dir])
        #expect(probe.hooks.isEmpty)
        #expect(probe.summaryHandoffs.isEmpty)
    }

    /// A finished transcript posts no per-stage notice; the settlement
    /// notifier owns the single "reunión lista".
    @Test func aFinishedTranscriptPostsNoStageNotice() async throws {
        let fixture = try SessionFixture()
        let (dir, probe) = try await run(fixture, minutesEnabled: false)
        #expect(SessionFiles.exists(SessionFiles.transcriptJSON, in: dir))
        #expect(probe.notices.isEmpty)
    }

    /// A failure says what failed and never sends the user to a log.
    @Test func aFailedTranscriptionPostsOneFailureNotice() async throws {
        let fixture = try SessionFixture()
        let (dir, probe) = try await run(fixture, minutesEnabled: false, brokenMeta: true)
        #expect(!SessionFiles.exists(SessionFiles.transcriptJSON, in: dir))
        #expect(probe.notices.count == 1)
        let notice = try #require(probe.notices.first)
        #expect(notice.title == Textos.Notificacion.transcripcionFallida)
        #expect(notice.body == Textos.Notificacion.transcripcionFallidaCuerpo("s1"))
        #expect(notice.kind == .failure(.transcription, retryable: true))
        #expect(notice.session == dir)
        #expect(!notice.body.contains("revisa") && !notice.body.contains(".log"))
    }

    @Test func minutesDisabledRunsHookAfterTranscript() async throws {
        let fixture = try SessionFixture()
        let (dir, probe) = try await run(fixture, minutesEnabled: false)
        #expect(SessionFiles.exists(SessionFiles.transcriptJSON, in: dir))
        #expect(!SessionFiles.exists(SessionFiles.minutesPending, in: dir))
        #expect(probe.handoffs.isEmpty)
        #expect(probe.hooks == [dir])
        #expect(probe.summaryHandoffs == [dir])
    }

    @Test func hookMarkerWrittenAndHookNotRepeated() async throws {
        let fixture = try SessionFixture()
        let (dir, probe) = try await run(fixture, minutesEnabled: false)
        #expect(SessionFiles.exists(SessionFiles.hookRan, in: dir))
        #expect(probe.hooks == [dir])

        let again = try SessionFixture()
        let (_, repeated) = try await run(again, minutesEnabled: false, hookAlreadyRan: true)
        #expect(repeated.hooks.isEmpty)
    }

    @Test func transcriptionDisabledRunsHookImmediatelyWithoutHandoff() async throws {
        let fixture = try SessionFixture()
        let (dir, probe) = try await run(fixture, minutesEnabled: true, transcriptionEnabled: false)
        #expect(probe.hooks == [dir])
        #expect(probe.handoffs.isEmpty)
        #expect(!SessionFiles.exists(SessionFiles.minutesPending, in: dir))
        #expect(probe.summaryHandoffs.isEmpty)
    }

    @Test func noHandoffRunsHookAfterTranscript() async throws {
        let fixture = try SessionFixture()
        let (dir, probe) = try await run(fixture, minutesEnabled: true, withHandoff: false)
        #expect(SessionFiles.exists(SessionFiles.transcriptJSON, in: dir))
        #expect(!SessionFiles.exists(SessionFiles.minutesPending, in: dir))
        #expect(probe.hooks == [dir])
        #expect(probe.summaryHandoffs == [dir])
    }

    @Test func summaryHandoffRunsOnlyOnNoMinutesBranchAfterHook() async throws {
        let fixture = try SessionFixture()
        let (dir, probe) = try await run(fixture, minutesEnabled: false)
        // The hook already ran before the summary handoff fires.
        #expect(probe.hooks == [dir])
        #expect(probe.summaryHandoffs == [dir])

        let withMinutes = try SessionFixture()
        let (_, probe2) = try await run(withMinutes, minutesEnabled: true)
        #expect(probe2.summaryHandoffs.isEmpty)
    }

    // MARK: Glossary

    @Test func glossaryCorrectsTheTranscriptAndKeepsTheRawText() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", transcript: false, pending: false)
        try Data().write(to: dir.appendingPathComponent("mic.caf"))
        let probe = ChainProbe()
        let coordinator = TranscriptionCoordinator(
            config: {
                ConfigValues(raw: ["glossary": [
                    ["term": "MeetingVox", "variants": ["miting vox"]] as [String: Any],
                    ["term": "Kafka", "variants": ["kafca"], "transcript": false] as [String: Any],
                ]])
            },
            makeEngine: { FakeEngine(text: "con miting vox y kafca") },
            hook: { probe.hook($0) },
            notify: { _ in }
        )
        await coordinator.setStatusHandler { probe.status($0) }
        await coordinator.enqueue(dir)
        try await waitUntil { probe.done }

        let document = try TranscriptDocument.read(from: dir)
        #expect(document.segments.map(\.text) == ["con MeetingVox y kafca"])
        #expect(document.segments.map(\.text_raw) == ["con miting vox y kafca"])
        #expect(document.engine == "fake")
        #expect(document.model == "fake-1")
        let md = try String(contentsOf: dir.appendingPathComponent(SessionFiles.transcriptMD), encoding: .utf8)
        #expect(md.contains("con MeetingVox y kafca"))
        #expect(!md.contains("miting vox"))
        let log = try String(contentsOf: dir.appendingPathComponent(SessionFiles.transcribeLog), encoding: .utf8)
        #expect(log.contains("glossary: 1 replacement(s)"))
    }

    @Test func applyGlossaryRewritesOnlyWhenTheTextChangesAndLogs() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false, text: "con miting vox")
        let coordinator = TranscriptionCoordinator(
            config: { ConfigValues(raw: ["glossary": [["term": "MeetingVox", "variants": ["miting vox"]] as [String: Any]]]) },
            makeEngine: { FakeEngine() },
            notify: { _ in }
        )

        #expect(await coordinator.applyGlossary(dir) == .rewritten(replacements: 1))
        #expect(await coordinator.applyGlossary(dir) == .unchanged)
        let bare = try fixture.session("s2", transcript: false, pending: false)
        #expect(await coordinator.applyGlossary(bare) == nil)

        let log = try String(contentsOf: dir.appendingPathComponent(SessionFiles.transcribeLog), encoding: .utf8)
        #expect(log.contains("apply glossary: 1 replacement(s), transcript rewritten"))
        #expect(log.contains("apply glossary: no change"))
        let bareLog = try String(contentsOf: bare.appendingPathComponent(SessionFiles.transcribeLog), encoding: .utf8)
        #expect(bareLog.contains("apply glossary failed"))
    }
}
