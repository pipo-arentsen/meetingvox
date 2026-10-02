import Foundation
import Testing
@testable import MeetingVox

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// The Tareas page's state: which rows the search and the owner filter leave,
/// the empty states, and what a row's meeting link does.
@MainActor
@Suite final class TasksPageModelTests {
    let root: URL
    private let now = date("2026-09-27T12:00:00Z")
    private let manual = ManualReloadScheduler()
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-tasks-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func session(_ name: String, _ started: String, title: String, tasks: [MeetingTask]?) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"started": "\#(started)", "duration_seconds": 600, "files": {"mic": "mic.caf"}}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(MeetingSummary(
            title: title, summary: "Resumen.", client: nil, topics: [], participants: [], source: .transcript,
            model: "m/x", generatedAt: date(started), tasks: tasks
        )).write(to: dir.appendingPathComponent(SessionFiles.summaryJSON))
    }

    func loaded() async -> MainWindowModel {
        let meetings = MeetingsModel(
            root: root, calendar: calendar, now: { [now] in now }, config: { ConfigValues(raw: [:]) }
        )
        let model = MainWindowModel(
            meetings: meetings, store: PipelineStatusStore(), calendar: calendar, now: { [now] in now },
            reloadScheduler: manual.scheduler, library: (try? TestLibrary.make().library)!
        )
        await model.reload().value
        return model
    }

    func populate() throws {
        try session("2026.09.26-1000", "2026-09-26T10:00:00Z", title: "Sync semanal", tasks: [
            MeetingTask(who: "Yo", what: "Revisar conciliación", when: nil),
            MeetingTask(who: "Participante 1", what: "Agendar demo", when: "viernes"),
            MeetingTask(who: nil, what: "Definir alcance", when: nil),
        ])
        // Older than the list's 30-day window: the page still lists it.
        try session("2026.05.01-1000", "2026-05-01T10:00:00Z", title: "Kickoff", tasks: [
            MeetingTask(who: "Participante 1", what: "Enviar propuesta", when: nil),
        ])
        try session("2026.09.20-1000", "2026-09-20T10:00:00Z", title: "Sin extraer", tasks: nil)
    }

    @Test func listsTheTasksOfEverySessionNotJustTheListsPage() async throws {
        try populate()
        let model = await loaded()
        #expect(model.tasks.rows.map(\.task.what) == ["Revisar conciliación", "Agendar demo", "Definir alcance", "Enviar propuesta"])
        #expect(model.tasks.visible == model.tasks.rows)
        #expect(model.tasks.counter == Textos.Tareas.contador(4, de: 4))
        #expect(model.tasks.notExtractedCount == 1)
    }

    @Test func rowsAreBuiltOncePerScanNotPerAccess() async throws {
        try populate()
        let model = await loaded()
        _ = model.tasks.rows
        let before = model.tasks.buildCount
        for _ in 0..<5 { _ = (model.tasks.rows, model.tasks.visible, model.tasks.counter, model.tasks.whoOptions, model.tasks.emptyState) }
        model.tasks.query = "demo"
        _ = model.tasks.visible
        #expect(model.tasks.buildCount == before, "already built for this scan")

        try session("2026.09.27-1000", "2026-09-27T10:00:00Z", title: "Nueva", tasks: [MeetingTask(who: nil, what: "Otra", when: nil)])
        await model.reload().value
        #expect(model.tasks.rows.map(\.task.what).contains("Otra"))
        #expect(model.tasks.buildCount == before + 1, "a rescan rebuilds once")
    }

    @Test func rowsRefreshAfterClassifyPatchesEntriesInPlace() async throws {
        try populate()
        let model = await loaded()
        _ = model.tasks.rows
        let revision = model.meetings.entriesRevision
        let built = model.tasks.buildCount
        let entry = try #require(model.meetings.entries.first { $0.dir.lastPathComponent == "2026.09.26-1000" })

        model.classify(entry, as: .personal)

        // The patch touched `entries` without a rescan: the revision moved, so
        // the page rebuilds its rows from the patched entries (once) and keeps
        // every task.
        #expect(model.meetings.entriesRevision > revision)
        #expect(model.tasks.rows.map(\.task.what) == ["Revisar conciliación", "Agendar demo", "Definir alcance", "Enviar propuesta"])
        #expect(model.tasks.buildCount == built + 1)
        _ = (model.tasks.rows, model.tasks.visible)
        #expect(model.tasks.buildCount == built + 1, "one rebuild per revision")
    }

    @Test func theOwnerFilterNarrowsTheRows() async throws {
        try populate()
        let model = await loaded()
        #expect(model.tasks.whoOptions == ["Participante 1", "Yo"])
        model.tasks.who = .person("Participante 1")
        #expect(model.tasks.visible.map(\.task.what) == ["Agendar demo", "Enviar propuesta"])
        #expect(model.tasks.counter == Textos.Tareas.contador(2, de: 4))
        model.tasks.who = .unassigned
        #expect(model.tasks.visible.map(\.task.what) == ["Definir alcance"])
    }

    @Test func searchAndOwnerCombineAndClearFiltersResetsBoth() async throws {
        try populate()
        let model = await loaded()
        model.tasks.query = "PROPUESTA"
        model.tasks.who = .person("Yo")
        #expect(model.tasks.visible.isEmpty)
        #expect(model.tasks.emptyState == .noMatches)
        #expect(model.tasks.isFiltering)

        model.tasks.clearFilters()
        #expect(model.tasks.query.isEmpty)
        #expect(model.tasks.who == .all)
        #expect(!model.tasks.isFiltering)
        #expect(model.tasks.emptyState == nil)
        #expect(model.tasks.visible.count == 4)
    }

    @Test func emptyStatesTellLoadingFromNoTasks() async throws {
        let meetings = MeetingsModel(
            root: root, calendar: calendar, now: { [now] in now }, config: { ConfigValues(raw: [:]) }
        )
        let model = MainWindowModel(
            meetings: meetings, store: PipelineStatusStore(), calendar: calendar, now: { [now] in now },
            reloadScheduler: manual.scheduler, library: (try? TestLibrary.make().library)!
        )
        #expect(model.tasks.emptyState == .loading, "before the first scan")
        await model.reload().value
        #expect(model.tasks.emptyState == .noTasks, "scanned an empty root")

        try session("2026.09.26-1000", "2026-09-26T10:00:00Z", title: "Sin tareas", tasks: [])
        await model.reload().value
        #expect(model.tasks.emptyState == .noTasks, "extracted, none")
    }

    @Test func openingARowShowsItsSessionOnTheResumenTab() async throws {
        try populate()
        let model = await loaded()
        model.tab = .transcripcion
        model.sidebar = .tareas
        let row = try #require(model.tasks.rows.first { $0.task.what == "Enviar propuesta" })

        model.tasks.open(row)

        #expect(model.sidebar == .reuniones)
        #expect(model.tab == .resumen)
        #expect(model.meetings.selection == [row.dir])
    }

    @Test func aRowsDateIsTheMeetingsDayInLocalTime() {
        let row = TaskRow(
            id: "x#0", dir: root, meetingTitle: "t", started: date("2026-09-24T02:30:00Z"),
            task: MeetingTask(who: nil, what: "w", when: nil)
        )
        #expect(row.dayText(timeZone: TimeZone(identifier: "UTC")!) == "Jue 24 sep")
        #expect(row.dayText(timeZone: TimeZone(identifier: "America/Santiago")!) == "Mié 23 sep")
        let undated = TaskRow(id: "y#0", dir: root, meetingTitle: "t", started: nil, task: row.task)
        #expect(undated.dayText(timeZone: TimeZone(identifier: "UTC")!) == nil)
    }
}

extension TasksPageModelTests {
    @Test func theSelectedOwnerStaysAChoiceEvenWhenNoTaskIsTheirsAnymore() async throws {
        try populate()
        let model = await loaded()
        model.tasks.who = .person("Participante 2")
        #expect(model.tasks.whoChoices == ["Participante 1", "Yo", "Participante 2"])
        #expect(model.tasks.visible.isEmpty)
    }
}
