import Foundation
import Testing
@testable import MeetingVox

/// A source whose answers the test scripts per query window; the start lookup
/// (provisional end = start + 10 min) can be held until `release()`.
private actor ScriptedSource: CalendarSource {
    private let startAnswer: [CalendarEventSnapshot]
    private let refineAnswer: [CalendarEventSnapshot]
    private var holdStart: Bool
    private var systemStatus: CalendarSystemStatus = .authorized
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var queries: [DateInterval] = []

    /// Windows whose end is at most this are the start lookup's.
    private static let provisionalEnd = CalendarFixtures.at(10)

    init(start: [CalendarEventSnapshot], refine: [CalendarEventSnapshot], holdStart: Bool = false) {
        startAnswer = start
        refineAnswer = refine
        self.holdStart = holdStart
    }

    func release() {
        holdStart = false
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func setStatus(_ status: CalendarSystemStatus) { systemStatus = status }

    func status() async -> CalendarSystemStatus { systemStatus }
    func requestFullAccess() async -> CalendarSystemStatus { .authorized }

    func events(overlapping interval: DateInterval) async throws -> [CalendarEventSnapshot] {
        queries.append(interval)
        if interval.end <= Self.provisionalEnd {
            if holdStart { await withCheckedContinuation { waiting.append($0) } }
            return startAnswer
        }
        return refineAnswer
    }
}

/// Collects what the follow-up wrote and how often it reindexed.
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [(CalendarEventRecord, URL)] = []
    private var reindexes = 0
    var existing = false

    var writes: [(CalendarEventRecord, URL)] { lock.withLock { written } }
    var reindexCount: Int { lock.withLock { reindexes } }

    func write(_ record: CalendarEventRecord, _ dir: URL) -> Bool {
        lock.withLock {
            if existing { return false }
            written.append((record, dir))
            return true
        }
    }

    func reindex() { lock.withLock { reindexes += 1 } }
}

/// A `calendar.enabled` the test flips mid-recording.
private final class Toggle: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

@MainActor @Suite struct CalendarStopFollowUpTests {
    private let dir = URL(fileURLWithPath: "/tmp/meetingvox-never-touched/2026.09.30-1500")
    private let started = CalendarFixtures.at(0)
    private let ended = CalendarFixtures.at(30)

    private func event(_ id: String, _ title: String) -> CalendarEventSnapshot {
        CalendarFixtures.snapshot(id: id, title: title, start: 0, end: 60)
    }

    private func link(
        _ source: any CalendarSource, enabled: Bool = true, sink: Sink
    ) -> CalendarSessionLink {
        let linker = CalendarLinker(source: source, isEnabled: { enabled }, now: { CalendarFixtures.at(31) })
        return CalendarSessionLink(
            linker: linker, write: { sink.write($0, $1) }, reindex: { sink.reindex() })
    }

    @Test func refinedMatchWinsAndIsWrittenOnce() async {
        let sink = Sink()
        let source = ScriptedSource(start: [event("s", "Start match")], refine: [event("r", "Refined")])
        let link = link(source, sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        await link.recordingStopped(endedAt: ended)?.value
        #expect(sink.writes.map { $0.0.title } == ["Refined"])
        #expect(sink.writes.first?.1 == dir)
        #expect(sink.reindexCount == 1)
    }

    @Test func refineFindingNothingKeepsTheStartMatch() async {
        let sink = Sink()
        let source = ScriptedSource(start: [event("s", "Start match")], refine: [])
        let link = link(source, sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        await link.recordingStopped(endedAt: ended)?.value
        #expect(sink.writes.map { $0.0.title } == ["Start match"])
        #expect(sink.reindexCount == 1)
    }

    @Test func noMatchAnywhereWritesAndReindexesNothing() async {
        let sink = Sink()
        let link = link(ScriptedSource(start: [], refine: []), sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        await link.recordingStopped(endedAt: ended)?.value
        #expect(sink.writes.isEmpty)
        #expect(sink.reindexCount == 0)
    }

    @Test func lateStartResultNeverWritesOnItsOwn() async {
        let sink = Sink()
        let source = ScriptedSource(start: [event("s", "Late")], refine: [], holdStart: true)
        let link = link(source, sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        await source.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(sink.writes.isEmpty) // recording still running: nothing writes
        #expect(sink.reindexCount == 0)
    }

    @Test func followUpWaitsForTheStartLookupThenWrites() async {
        let sink = Sink()
        let source = ScriptedSource(start: [event("s", "Late")], refine: [], holdStart: true)
        let link = link(source, sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        let followUp = link.recordingStopped(endedAt: ended)
        for _ in 0..<20 { await Task.yield() }
        #expect(sink.writes.isEmpty) // still waiting for the held start lookup
        await source.release()
        await followUp?.value
        #expect(sink.writes.map { $0.0.title } == ["Late"])
    }

    @Test func terminationCancelsTheStartLookupAndWritesNothing() async {
        let sink = Sink()
        let source = ScriptedSource(start: [event("s", "Dropped")], refine: [event("r", "Never")], holdStart: true)
        let link = link(source, sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        link.recordingTerminated()
        #expect(!link.hasStartLookup)
        await source.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(sink.writes.isEmpty)
        #expect(sink.reindexCount == 0)
        #expect(await source.queries.count <= 1) // never the refine query
    }

    @Test func terminationAfterAnUnfinishedStartDoesNotSpawnAFollowUp() async {
        let sink = Sink()
        let link = link(ScriptedSource(start: [event("s", "x")], refine: []), sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        link.recordingTerminated()
        #expect(link.recordingStopped(endedAt: ended) == nil)
        #expect(sink.writes.isEmpty)
    }

    @Test func existingKeyIsNotOverwrittenAndNotReindexed() async {
        let sink = Sink()
        sink.existing = true
        let link = link(ScriptedSource(start: [event("s", "New")], refine: []), sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        await link.recordingStopped(endedAt: ended)?.value
        #expect(sink.writes.isEmpty)
        #expect(sink.reindexCount == 0)
    }

    @Test func disabledCreatesNoLookupAndNoFollowUp() async {
        let sink = Sink()
        let source = ScriptedSource(start: [event("s", "x")], refine: [])
        let link = link(source, enabled: false, sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        #expect(!link.hasStartLookup)
        #expect(link.recordingStopped(endedAt: ended) == nil)
        #expect(await source.queries.isEmpty)
    }

    @Test func stopClearsTheStartLookupSoTheNextRecordingStartsFresh() async {
        let sink = Sink()
        let link = link(ScriptedSource(start: [event("s", "x")], refine: []), sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        let followUp = link.recordingStopped(endedAt: ended)
        #expect(!link.hasStartLookup)
        #expect(link.recordingStopped(endedAt: ended) == nil)
        await followUp?.value
    }

    @Test func aWriteFailureIsSwallowedWithoutReindex() async {
        let sink = Sink()
        let linker = CalendarLinker(
            source: ScriptedSource(start: [event("s", "x")], refine: []), isEnabled: { true }, now: { CalendarFixtures.at(31) })
        let link = CalendarSessionLink(
            linker: linker, write: { _, _ in throw CocoaError(.fileWriteUnknown) }, reindex: { sink.reindex() })
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        await link.recordingStopped(endedAt: ended)?.value
        #expect(sink.reindexCount == 0)
    }

    // MARK: Correction: the gate is checked again at stop

    @Test func disabledMidRecordingWritesNothing() async {
        let sink = Sink()
        let toggle = Toggle()
        let linker = CalendarLinker(
            source: ScriptedSource(start: [event("s", "Start match")], refine: [event("r", "Refined")]),
            isEnabled: { toggle.value }, now: { CalendarFixtures.at(31) })
        let link = CalendarSessionLink(linker: linker, write: { sink.write($0, $1) }, reindex: { sink.reindex() })
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        toggle.value = false
        await link.recordingStopped(endedAt: ended)?.value
        #expect(sink.writes.isEmpty)
        #expect(sink.reindexCount == 0)
    }

    @Test func accessRevokedMidRecordingWritesNothing() async {
        let sink = Sink()
        let source = ScriptedSource(start: [event("s", "Start match")], refine: [])
        let link = link(source, sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        await source.setStatus(.denied)
        await link.recordingStopped(endedAt: ended)?.value
        #expect(sink.writes.isEmpty)
    }

    @Test func aStartMatchBeginningAfterTheStopIsNotWritten() async {
        let sink = Sink()
        // Matched the provisional window (0..10), but starts after the real stop (30).
        let late = CalendarFixtures.snapshot(id: "late", title: "Later", start: 5, end: 60)
        let source = ScriptedSource(start: [late], refine: [])
        let link = link(source, sink: sink)
        link.recordingStarted(dir: dir, startedAt: started, meetingApp: nil)
        await link.recordingStopped(endedAt: CalendarFixtures.at(2))?.value
        #expect(sink.writes.isEmpty)
        #expect(sink.reindexCount == 0)
    }
}
