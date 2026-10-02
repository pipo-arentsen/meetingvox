import Foundation
import Testing
@testable import MeetingVox

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// The list's full-text search (A3): summary matches show at once, transcript
/// and minutes matches arrive through the debounced index, a stale answer is
/// never used, and each rescan refreshes the index. Real temp folders, the
/// scheduler driven by hand.
@MainActor
@Suite final class MeetingsModelSearchTests {
    let root: URL
    private let now = date("2026-09-27T12:00:00Z")
    private let manual = ManualReloadScheduler()
    private let index = FullTextIndex()
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-search-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try session("2026.09.20-1000", "2026-09-20T10:00:00Z", text: "hola a todos", title: "Kickoff")
        try session("2026.08.15-1000", "2026-08-15T10:00:00Z", text: "la cotización final llegó")
        try session("2026.06.01-1000", "2026-06-01T10:00:00Z", text: "nada", title: "Presupuesto Proveedor")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func session(_ name: String, _ started: String, text: String, title: String? = nil) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"started": "\#(started)", "duration_seconds": 600, "files": {"mic": "mic.caf"}}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
        try Data(#"{"segments": [{"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "\#(text)"}]}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        if let title {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(MeetingSummary(
                title: title, summary: "Resumen.", client: nil, topics: [], participants: [],
                source: .transcript, model: "m/x", generatedAt: date(started)
            )).write(to: dir.appendingPathComponent(SessionFiles.summaryJSON))
        }
    }

    private func makeModel(hindsight: Bool = false) -> MeetingsModel {
        MeetingsModel(
            root: root, calendar: calendar, now: { [now] in now },
            config: { ConfigValues(raw: ["hindsight": ["enabled": hindsight, "bank": "meetingvox"]]) },
            fullText: index, searchScheduler: manual.scheduler
        )
    }

    private func loaded(hindsight: Bool = false) async -> MeetingsModel {
        let model = makeModel(hindsight: hindsight)
        await model.reload().value
        await model.indexTask?.value
        return model
    }

    private func names(_ model: MeetingsModel) -> [String] { model.filtered.map(\.dir.lastPathComponent) }

    // MARK: - Immediate and deferred

    @Test func aSummaryMatchShowsImmediatelyAndNothingIsScheduledForEmptyQueries() async {
        let model = await loaded()
        #expect(manual.pending == 0)
        model.query = "presupuesto"
        #expect(names(model) == ["2026.06.01-1000"], "metadata needs no index round trip")
        #expect(manual.pending == 1)
        model.query = "  "
        #expect(manual.pending == 0, "a blank query cancels the pending search")
        #expect(model.searchHit(for: model.entries[0]) == nil)
    }

    @Test func aTranscriptOnlyMatchArrivesAfterTheSchedulerWithItsSnippet() async throws {
        let model = await loaded()
        model.query = "cotizacion FINAL"
        #expect(names(model).isEmpty, "not until the debounced search answers")

        manual.fire()
        await model.searchTask?.value

        #expect(names(model) == ["2026.08.15-1000"])
        let entry = try #require(model.filtered.first)
        let hit = try #require(model.searchHit(for: entry))
        #expect(hit.source == .transcript)
        #expect(hit.lineID == 0)
        #expect(hit.snippet.text == "la cotización final llegó")
    }

    @Test func aMinutesOnlyMatchCarriesAMinutesHit() async throws {
        try Data("# Acta\n- Se aprobó el presupuestoanual".utf8)
            .write(to: root.appendingPathComponent("2026.09.20-1000").appendingPathComponent(SessionFiles.minutes))
        let model = await loaded()
        model.query = "presupuestoanual"
        manual.fire()
        await model.searchTask?.value
        let entry = try #require(model.filtered.first)
        #expect(model.searchHit(for: entry)?.source == .minutes)
    }

    @Test func aStaleQueryIsNeverUsed() async {
        let model = await loaded()
        model.query = "cotizacion"
        manual.fire()
        let inFlight = model.searchTask
        model.query = "otra cosa"          // before the first answer lands
        await inFlight?.value

        #expect(names(model).isEmpty, "the old query's hit must not leak into the new query")
        #expect(model.searchHit(for: model.entries[0]) == nil)

        manual.fire()
        await model.searchTask?.value
        #expect(names(model).isEmpty)
    }

    @Test func anAnswerBelongsOnlyToTheQueryThatAskedForIt() async {
        let model = await loaded()
        model.query = "cotizacion"
        manual.fire()
        await model.searchTask?.value
        #expect(names(model) == ["2026.08.15-1000"])
        model.query = "cotizacion x"
        #expect(names(model).isEmpty, "the previous answer no longer applies to the changed query")
    }

    // MARK: - Rescan and facts

    @Test func aRescanRefreshesTheIndexAndAnActiveSearchSeesTheNewText() async throws {
        let model = await loaded()
        model.query = "nuevisimo"
        manual.fire()
        await model.searchTask?.value
        #expect(names(model).isEmpty)

        try Data("# Acta\n- texto nuevisimo".utf8)
            .write(to: root.appendingPathComponent("2026.09.20-1000").appendingPathComponent(SessionFiles.minutes))
        await model.reload().value
        await model.indexTask?.value
        await model.searchTask?.value

        #expect(names(model) == ["2026.09.20-1000"])
        #expect(await index.loadCount == 4, "3 sessions once, then only the edited one")
    }

    @Test func factsAreReadAgainForRowsThatOnlyTheSearchBrought() async {
        let model = await loaded(hindsight: true)
        #expect(!model.facts.keys.contains { $0.lastPathComponent == "2026.08.15-1000" }, "outside the 30 days")

        model.query = "cotizacion"
        manual.fire()
        await model.searchTask?.value
        await model.factsTask?.value

        #expect(model.facts.keys.contains { $0.lastPathComponent == "2026.08.15-1000" })
    }

    // MARK: - Closing

    @Test func clearingDropsTheAnswersAndTheIndexAndTheNextReloadRebuildsIt() async {
        let model = await loaded()
        model.query = "cotizacion"
        manual.fire()
        await model.searchTask?.value
        #expect(await index.cachedCount == 3)

        model.clearFullText()
        await model.indexTask?.value
        #expect(await index.cachedCount == 0)
        #expect(names(model).isEmpty, "no stale answer survives")

        await model.reload().value
        await model.indexTask?.value
        #expect(await index.cachedCount == 3)
    }

    @Test func aScanThatFinishesAfterClearingDoesNotRebuildTheIndex() async {
        let model = makeModel()
        let scan = model.reload()
        model.clearFullText()
        await scan.value
        await model.indexTask?.value
        #expect(await index.cachedCount == 0)
    }

    // MARK: - Lazy index, cancellation, no flicker (correction)

    @Test func reloadingWithAnEmptyQueryNeverBuildsTheIndex() async {
        let model = makeModel()
        await model.reload().value
        await model.reload().value
        #expect(model.indexTask == nil)
        #expect(await index.loadCount == 0)
        #expect(await index.cachedCount == 0)

        model.query = "cotizacion"
        await model.indexTask?.value
        #expect(await index.cachedCount == 3, "built once the query is non-empty")
    }

    @Test func aNewQueryAndClearingCancelTheTasksInFlight() async {
        let model = await loaded()
        model.query = "cotizacion"
        manual.fire()
        let firstSearch = model.searchTask
        model.query = "cotizacion final"
        #expect(firstSearch?.isCancelled == true, "a new query cancels the running search")

        manual.fire()
        let secondSearch = model.searchTask
        let indexBefore = model.indexTask
        model.clearFullText()
        #expect(secondSearch?.isCancelled == true)
        #expect(indexBefore?.isCancelled == true)
    }

    @Test func aSelectedTextHitRowStaysWhileTheNextAnswerIsPending() async throws {
        let model = await loaded()
        model.query = "cotizacion"
        manual.fire()
        await model.searchTask?.value
        let dir = try #require(model.filtered.first?.dir)
        model.selection = [dir]

        model.query = "cotizacion f"
        #expect(model.filtered.map(\.dir) == [dir], "the open row must not vanish before the new answer")
        #expect(model.selectedVisible == [dir])

        manual.fire()
        await model.searchTask?.value
        #expect(model.filtered.map(\.dir) == [dir])
    }
}
