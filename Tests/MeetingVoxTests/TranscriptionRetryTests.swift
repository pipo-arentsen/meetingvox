import Foundation
import Testing
@testable import MeetingVox

private struct RetryFakeEngine: TranscriptionEngine {
    let name = "fake"
    let model = "fake-1"
    func prepare() async throws {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        [TranscriptSegment(start: 0, end: 1, text: "hola")]
    }
    func release() async {}
}

/// Holds `transcribe` until opened, so a job can be observed while running.
private final class GateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _open = false
    var isOpen: Bool { lock.withLock { _open } }
    func open() { lock.withLock { _open = true } }
}

private struct GatedEngine: TranscriptionEngine {
    let name = "fake"
    let model = "fake-1"
    let gate: GateBox
    func prepare() async throws {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        while !gate.isOpen { try await Task.sleep(for: .milliseconds(10)) }
        return [TranscriptSegment(start: 0, end: 1, text: "hola")]
    }
    func release() async {}
}

private final class RetryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _summaryHandoffs: [URL] = []
    private var _notices: [Notice] = []
    var summaryHandoffs: [URL] { lock.withLock { _summaryHandoffs } }
    var notices: [Notice] { lock.withLock { _notices } }
    func summaryHandoff(_ dir: URL) { lock.withLock { _summaryHandoffs.append(dir) } }
    func notify(_ notice: Notice) { lock.withLock { _notices.append(notice) } }
}

/// "Reintentar" on a transcription failure notice.
@Suite struct TranscriptionRetryTests {
    private func makeCoordinator(_ probe: RetryProbe, transcriptionEnabled: Bool = true) -> TranscriptionCoordinator {
        TranscriptionCoordinator(
            config: {
                ConfigValues(raw: ["minutes": ["enabled": false], "transcription": ["enabled": transcriptionEnabled]])
            },
            makeEngine: { RetryFakeEngine() },
            summaryHandoff: { @Sendable dir in probe.summaryHandoff(dir) },
            hook: { _ in },
            notify: { probe.notify($0) }
        )
    }

    /// A session whose first transcription fails (unreadable meta.json), the
    /// way a real failure leaves it: no transcript, nothing else.
    private func failedSession(_ fixture: SessionFixture) throws -> URL {
        let dir = try fixture.session("s1", transcript: false, pending: false)
        try Data().write(to: dir.appendingPathComponent("mic.caf"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent(SessionFiles.meta))
        return dir
    }

    private func repairMeta(_ dir: URL) throws {
        try Data(#"{"started": "2026-09-23T14:05:00Z", "duration_seconds": 60, "files": {"mic": "mic.caf"}}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
    }

    @Test func retryTranscribesASessionWhoseTranscriptionFailed() async throws {
        let fixture = try SessionFixture()
        let dir = try failedSession(fixture)
        let probe = RetryProbe()
        let coordinator = makeCoordinator(probe)

        await coordinator.enqueue(dir)
        try await waitUntil { probe.notices.count == 1 }
        #expect(!SessionFiles.exists(SessionFiles.transcriptJSON, in: dir))

        try repairMeta(dir)
        #expect(await coordinator.retry(dir))
        try await waitUntil { probe.summaryHandoffs == [dir] }

        #expect(SessionFiles.exists(SessionFiles.transcriptJSON, in: dir))
        #expect(probe.notices.count == 1)
    }

    @Test func isQueuedOrRunningFollowsTheJob() async throws {
        let fixture = try SessionFixture()
        let dir = try failedSession(fixture)
        try repairMeta(dir)
        let other = try fixture.session("s2", transcript: false, pending: false)
        let probe = RetryProbe()
        let gate = GateBox()
        let coordinator = TranscriptionCoordinator(
            config: { ConfigValues(raw: ["minutes": ["enabled": false]]) },
            makeEngine: { GatedEngine(gate: gate) },
            summaryHandoff: { @Sendable dir in probe.summaryHandoff(dir) },
            hook: { _ in },
            notify: { probe.notify($0) }
        )
        #expect(await coordinator.isQueuedOrRunning(dir) == false)

        await coordinator.enqueue(dir)
        // Queued or running (held by the gate): either way, true, and by
        // standardized path.
        #expect(await coordinator.isQueuedOrRunning(dir))
        #expect(await coordinator.isQueuedOrRunning(dir.appendingPathComponent(".").standardizedFileURL))
        #expect(await coordinator.isQueuedOrRunning(other) == false)

        gate.open()
        try await waitUntil { probe.summaryHandoffs == [dir] }
        // `current` clears right after the handoff: poll the actor.
        var still = true
        for _ in 0..<200 where still {
            still = await coordinator.isQueuedOrRunning(dir)
            if still { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(!still)
    }

    @Test func aFailedTranscriptionIsNotQueuedOrRunning() async throws {
        let fixture = try SessionFixture()
        let dir = try failedSession(fixture)
        let probe = RetryProbe()
        let coordinator = makeCoordinator(probe)

        await coordinator.enqueue(dir)
        try await waitUntil { probe.notices.count == 1 }
        #expect(await coordinator.isQueuedOrRunning(dir) == false)
    }

    @Test func retryDoesNothingOnceTheTranscriptExists() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", transcript: true, pending: false)
        let probe = RetryProbe()
        let coordinator = makeCoordinator(probe)

        #expect(await coordinator.retry(dir) == false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.summaryHandoffs.isEmpty)
    }

    @Test func retryDoesNothingWhileTheSessionIsAlreadyQueued() async throws {
        let fixture = try SessionFixture()
        let dir = try failedSession(fixture)
        try repairMeta(dir)
        let probe = RetryProbe()
        let coordinator = makeCoordinator(probe)

        #expect(await coordinator.retry(dir))
        // Queued (or already running): a second tap must not double the job.
        #expect(await coordinator.retry(dir) == false)
        try await waitUntil { probe.summaryHandoffs == [dir] }
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.summaryHandoffs == [dir])
    }

    @Test func retryDoesNothingWithTranscriptionDisabled() async throws {
        let fixture = try SessionFixture()
        let dir = try failedSession(fixture)
        try repairMeta(dir)
        let probe = RetryProbe()
        let coordinator = makeCoordinator(probe, transcriptionEnabled: false)

        #expect(await coordinator.retry(dir) == false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!SessionFiles.exists(SessionFiles.transcriptJSON, in: dir))
    }

    @Test func retryLogsWhyItRan() async throws {
        let fixture = try SessionFixture()
        let dir = try failedSession(fixture)
        try repairMeta(dir)
        let probe = RetryProbe()
        let coordinator = makeCoordinator(probe)

        await coordinator.retry(dir)
        try await waitUntil { probe.summaryHandoffs == [dir] }
        let log = try String(contentsOf: dir.appendingPathComponent(SessionFiles.transcribeLog), encoding: .utf8)
        #expect(log.contains("transcription retry requested"))
    }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _failed = false
    private var _idle = 0
    var failed: Bool { lock.withLock { _failed } }
    var idle: Int { lock.withLock { _idle } }
    func record(_ status: TranscriptionCoordinator.Status) {
        lock.withLock {
            switch status {
            case .failed: _failed = true
            case .idle: _idle += 1
            case .transcribing: break
            }
        }
    }
}

/// A session folder moved to the Trash before its job ran.
@Suite struct TranscriptionMissingFolderTests {
    private func makeCoordinator(_ probe: RetryProbe, hooks: HookBox) -> TranscriptionCoordinator {
        TranscriptionCoordinator(
            config: { ConfigValues(raw: ["minutes": ["enabled": false], "transcription": ["enabled": true]]) },
            makeEngine: { RetryFakeEngine() },
            summaryHandoff: { @Sendable dir in probe.summaryHandoff(dir) },
            hook: { dir in hooks.add(dir) },
            notify: { probe.notify($0) }
        )
    }

    final class HookBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _dirs: [URL] = []
        var dirs: [URL] { lock.withLock { _dirs } }
        func add(_ dir: URL) { lock.withLock { _dirs.append(dir) } }
    }

    @Test func aTrashedSessionIsDroppedWithoutNoticeFailureHookOrHandoff() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", transcript: false, pending: false)
        try FileManager.default.removeItem(at: dir)
        let probe = RetryProbe()
        let hooks = HookBox()
        let statuses = StatusBox()
        let coordinator = makeCoordinator(probe, hooks: hooks)
        await coordinator.setStatusHandler { statuses.record($0) }

        await coordinator.enqueue(dir)
        try await waitUntil { statuses.idle >= 1 }

        #expect(probe.notices.isEmpty)
        #expect(probe.summaryHandoffs.isEmpty)
        #expect(hooks.dirs.isEmpty)
        #expect(!statuses.failed)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func retryOfATrashedSessionIsRefused() async throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", transcript: false, pending: false)
        try FileManager.default.removeItem(at: dir)
        let probe = RetryProbe()
        let coordinator = makeCoordinator(probe, hooks: HookBox())

        #expect(await coordinator.retry(dir) == false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.notices.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}

@Suite struct SessionHookMissingFolderTests {
    @Test func theHookIsNotLaunchedForAMissingFolder() {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("hook-gone-\(UUID().uuidString)")
        var launched = false
        var lines: [String] = []

        let ran = SessionHook.runOnce(for: gone, log: { lines.append($0) }) { launched = true }

        #expect(!ran)
        #expect(!launched)
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func theHookStillRunsOnceForAnExistingFolder() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", transcript: false, pending: false)
        var launches = 0
        SessionHook.runOnce(for: dir, log: { _ in }) { launches += 1 }
        SessionHook.runOnce(for: dir, log: { _ in }) { launches += 1 }
        #expect(launches == 1)
    }
}

