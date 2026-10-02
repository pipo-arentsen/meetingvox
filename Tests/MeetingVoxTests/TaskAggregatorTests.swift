import Foundation
import Testing
@testable import MeetingVox

@Suite("TaskAggregator")
struct TaskAggregatorTests {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func entry(
        _ folder: String, started: String?, title: String = "Reunión", tasks: [MeetingTask]?, hasSummary: Bool = true
    ) -> MeetingEntry {
        var entry = MeetingEntry(
            dir: URL(fileURLWithPath: "/root/\(folder)"), started: started.map(date), durationSeconds: 600, app: nil,
            summary: hasSummary
                ? MeetingSummary(
                    title: title, summary: "s", client: nil, topics: [], participants: [], source: .transcript,
                    model: "m", generatedAt: date("2026-09-24T11:00:00Z"), tasks: tasks
                )
                : nil,
            hasMinutes: false, hasTranscript: true
        )
        entry.summaryObjectReadable = hasSummary
        entry.summaryHasTasksKey = hasSummary && tasks != nil
        return entry
    }

    private func task(_ who: String?, _ what: String, _ when: String? = nil) -> MeetingTask {
        MeetingTask(who: who, what: what, when: when)
    }

    private var sample: [MeetingEntry] {
        [
            entry("old", started: "2026-09-20T10:00:00Z", title: "Kickoff", tasks: [task("Participante 1", "Enviar propuesta", "viernes")]),
            entry("new", started: "2026-09-28T10:00:00Z", title: "Sync semanal", tasks: [
                task("Yo", "Revisar conciliación bancaria"), task(nil, "Definir alcance"), task("Participante 1", "Agendar demo"),
            ]),
            entry("none", started: "2026-09-25T10:00:00Z", tasks: []),
            entry("legacy", started: "2026-09-26T10:00:00Z", tasks: nil),
            entry("nosummary", started: "2026-09-27T10:00:00Z", tasks: nil, hasSummary: false),
        ]
    }

    @Test func flattensNewestMeetingFirstKeepingEachMeetingsTaskOrder() {
        let rows = TaskAggregator.build(sample)
        #expect(rows.map(\.task.what) == ["Revisar conciliación bancaria", "Definir alcance", "Agendar demo", "Enviar propuesta"])
        #expect(rows.map(\.meetingTitle) == ["Sync semanal", "Sync semanal", "Sync semanal", "Kickoff"])
        #expect(Set(rows.map(\.id)).count == rows.count, "row ids are unique")
    }

    @Test func aTaskWithoutAnOwnerIsKept() {
        let rows = TaskAggregator.build(sample)
        #expect(rows.contains { $0.task.who == nil && $0.task.what == "Definir alcance" })
    }

    @Test func undatedMeetingsComeLast() {
        let rows = TaskAggregator.build([
            entry("undated", started: nil, tasks: [task("Participante 1", "Sin fecha")]),
            entry("dated", started: "2026-09-20T10:00:00Z", tasks: [task("Participante 1", "Con fecha")]),
        ])
        #expect(rows.map(\.task.what) == ["Con fecha", "Sin fecha"])
    }

    @Test func aBlankTitleFallsBackToTheFolderName() {
        let rows = TaskAggregator.build([entry("2026.09.28-1000", started: "2026-09-28T10:00:00Z", title: "  ", tasks: [task("Participante 1", "x")])])
        #expect(rows.first?.meetingTitle == "2026.09.28-1000")
    }

    @Test func noTasksAnywhereBuildsNothing() {
        #expect(TaskAggregator.build([entry("a", started: nil, tasks: []), entry("b", started: nil, tasks: nil)]).isEmpty)
        #expect(TaskAggregator.build([]).isEmpty)
    }

    @Test func whoOptionsAreDistinctPeopleSortedAndCaseInsensitive() {
        let rows = TaskAggregator.build([
            entry("a", started: "2026-09-28T10:00:00Z", tasks: [task("Yo", "1"), task("participante 1", "2"), task(nil, "3"), task("  ", "4")]),
            entry("b", started: "2026-09-27T10:00:00Z", tasks: [task("Participante 1", "5"), task("Participante 2", "6")]),
        ])
        #expect(TaskAggregator.whoOptions(in: rows) == ["participante 1", "Participante 2", "Yo"])
    }

    @Test func filteringByPersonKeepsOnlyThatPerson() {
        let rows = TaskAggregator.build(sample)
        let ana = TaskAggregator.filter(rows, query: "", who: .person("participante 1"))
        #expect(ana.map(\.task.what) == ["Agendar demo", "Enviar propuesta"])
    }

    @Test func unassignedKeepsTasksWithoutAnOwner() {
        let rows = TaskAggregator.build(sample + [entry("blank", started: "2026-09-29T10:00:00Z", tasks: [task("  ", "Owner en blanco")])])
        let unassigned = TaskAggregator.filter(rows, query: "", who: .unassigned)
        #expect(unassigned.map(\.task.what) == ["Owner en blanco", "Definir alcance"])
    }

    @Test func allKeepsEverything() {
        let rows = TaskAggregator.build(sample)
        #expect(TaskAggregator.filter(rows, query: "  ", who: .all) == rows)
    }

    @Test func searchIsDiacriticAndCaseInsensitiveAndAllTokensMustMatch() {
        let rows = TaskAggregator.build(sample)
        #expect(TaskAggregator.filter(rows, query: "CONCILIACION", who: .all).map(\.task.what) == ["Revisar conciliación bancaria"])
        #expect(TaskAggregator.filter(rows, query: "revisar bancaria", who: .all).count == 1)
        #expect(TaskAggregator.filter(rows, query: "revisar demo", who: .all).isEmpty)
    }

    @Test func searchCoversTheOwnerTheDeadlineAndTheMeetingTitle() {
        let rows = TaskAggregator.build(sample)
        #expect(TaskAggregator.filter(rows, query: "viernes", who: .all).map(\.task.what) == ["Enviar propuesta"])
        #expect(TaskAggregator.filter(rows, query: "kickoff", who: .all).map(\.task.what) == ["Enviar propuesta"])
        #expect(TaskAggregator.filter(rows, query: "yo", who: .all).contains { $0.task.who == "Yo" })
    }

    @Test func searchAndOwnerCombine() {
        let rows = TaskAggregator.build(sample)
        #expect(TaskAggregator.filter(rows, query: "propuesta", who: .person("Participante 1")).count == 1)
        #expect(TaskAggregator.filter(rows, query: "propuesta", who: .person("Yo")).isEmpty)
    }

    @Test func notExtractedCountsSummariesWithoutATasksKey() {
        #expect(TaskAggregator.notExtractedCount(sample) == 1, "only the legacy summary: [] is extracted, no summary is not countable")
    }

    @Test func notExtractedAgreesWithTheBackfillsCandidatePredicate() {
        var failed = entry("failed", started: nil, tasks: nil)
        failed.tasksFailed = true
        var summaryPending = entry("sp", started: nil, tasks: nil)
        summaryPending.summaryState = .pending
        var minutesPending = entry("mp", started: nil, tasks: nil)
        minutesPending.minutesPending = true
        var malformed = entry("bad", started: nil, tasks: nil)
        malformed.summaryHasTasksKey = true  // a `tasks` key that decodes as nil
        var bare = entry("bare", started: nil, tasks: nil, hasSummary: false)
        bare.summaryObjectReadable = true  // readable object that is not a MeetingSummary
        let all = [failed, summaryPending, minutesPending, malformed, bare] + sample
        #expect(TaskAggregator.notExtractedCount(all) == 2, "only `bare` and the sample's legacy entry")
        for e in all {
            #expect((TaskAggregator.notExtractedCount([e]) == 1) == TasksBackfill.isCandidate(e.tasksBackfillFacts))
        }
    }

    @Test func tasksColumnDistinguishesNotExtractedFromNone() {
        func state(_ tasks: [MeetingTask]?) -> TasksColumnState {
            TasksColumnState.of(
                MeetingSummary(
                    title: "t", summary: "s", client: nil, topics: [], participants: [], source: .transcript,
                    model: "m", generatedAt: date("2026-09-24T11:00:00Z"), tasks: tasks
                )
            )
        }
        #expect(state(nil) == .notExtracted)
        #expect(state([]) == .none)
        #expect(state([task("Participante 1", "x")]) == .list([task("Participante 1", "x")]))
    }
}
