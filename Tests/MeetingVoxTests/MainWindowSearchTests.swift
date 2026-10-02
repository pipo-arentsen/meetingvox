import Foundation
import Testing
@testable import MeetingVox

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// Opening a search hit from the list (A3): the query and filters stay, the
/// session is selected alone, the tab follows the source, and a transcript
/// hit sets the line the Transcripción tab jumps to.
@MainActor
@Suite final class MainWindowSearchTests {
    let root: URL
    private let manual = ManualReloadScheduler()
    private let index = FullTextIndex()
    private let now = date("2026-09-27T12:00:00Z")
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-main-search-\(UUID().uuidString)", isDirectory: true)
        for (name, started, text) in [
            ("2026.09.27-1000", "2026-09-27T10:00:00Z", "hablamos del plazo"),
            ("2026.09.26-1500", "2026-09-26T15:00:00Z", "la cotización final"),
        ] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"started": "\#(started)", "duration_seconds": 600, "files": {"mic": "mic.caf"}}"#.utf8)
                .write(to: dir.appendingPathComponent(SessionFiles.meta))
            try Data(#"{"segments": [{"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "primera"}, {"speaker": "them", "start_ms": 2000, "end_ms": 3000, "text": "\#(text)"}]}"#.utf8)
                .write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        }
        try Data("# Acta\n- el presupuesto anual".utf8)
            .write(to: root.appendingPathComponent("2026.09.27-1000").appendingPathComponent(SessionFiles.minutes))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func loaded() async -> MainWindowModel {
        let meetings = MeetingsModel(
            root: root, calendar: calendar, now: { [now] in now }, config: { ConfigValues(raw: [:]) },
            fullText: index, searchScheduler: manual.scheduler
        )
        let model = MainWindowModel(
            meetings: meetings, store: PipelineStatusStore(), calendar: calendar, now: { [now] in now },
            reloadScheduler: manual.scheduler, library: (try? TestLibrary.make().library)!
        )
        await model.reload().value
        await meetings.indexTask?.value
        return model
    }

    private func search(_ model: MainWindowModel, _ query: String) async {
        model.meetings.query = query
        manual.fire()
        await model.meetings.searchTask?.value
    }

    @Test func aTranscriptHitKeepsTheQuerySelectsTheRowAndTargetsItsLine() async throws {
        let model = await loaded()
        model.tab = .resumen
        await search(model, "cotizacion")
        let entry = try #require(model.meetings.filtered.first)
        let hit = try #require(model.meetings.searchHit(for: entry))

        model.openSearchHit(entry.dir, hit)

        #expect(model.meetings.query == "cotizacion", "the filters stay so the user can go back to the list")
        #expect(model.meetings.selection == [entry.dir])
        #expect(model.tab == .transcripcion)
        #expect(model.transcriptTarget?.dir == entry.dir)
        #expect(model.transcriptTarget?.lineID == 1)
        #expect(model.transcriptLineTarget(for: entry.dir) == 1)
        #expect(model.transcriptLineTarget(for: root) == nil, "another session has no target")
    }

    @Test func tappingTheSameSnippetAgainIsANewTarget() async throws {
        let model = await loaded()
        await search(model, "cotizacion")
        let entry = try #require(model.meetings.filtered.first)
        let hit = try #require(model.meetings.searchHit(for: entry))

        model.openSearchHit(entry.dir, hit)
        let first = model.transcriptTargetNonce(for: entry.dir)
        model.openSearchHit(entry.dir, hit)
        #expect(model.transcriptTargetNonce(for: entry.dir) != first, "the tab's task id must change")
        #expect(model.transcriptLineTarget(for: entry.dir) == 1)
    }

    @Test func aMinutesHitOpensTheMinutaTabWithoutALineTarget() async throws {
        let model = await loaded()
        model.tab = .transcripcion
        await search(model, "presupuesto anual")
        let entry = try #require(model.meetings.filtered.first)
        let hit = try #require(model.meetings.searchHit(for: entry))
        #expect(hit.source == .minutes)

        model.openSearchHit(entry.dir, hit)

        #expect(model.tab == .minuta)
        #expect(model.transcriptTarget == nil)
    }

    @Test func leavingTheTranscriptTabDropsTheTarget() async throws {
        let model = await loaded()
        await search(model, "cotizacion")
        let entry = try #require(model.meetings.filtered.first)
        model.openSearchHit(entry.dir, try #require(model.meetings.searchHit(for: entry)))
        #expect(model.transcriptTarget != nil)

        model.tab = .resumen
        #expect(model.transcriptTarget == nil)
    }

    @Test func focusingASessionDropsAnOldTarget() async throws {
        let model = await loaded()
        await search(model, "cotizacion")
        let entry = try #require(model.meetings.filtered.first)
        model.openSearchHit(entry.dir, try #require(model.meetings.searchHit(for: entry)))

        model.focus(on: entry.dir)
        #expect(model.transcriptTarget == nil)
    }

    @Test func closingTheWindowClearsTheIndexAndTheAnswers() async {
        let model = await loaded()
        model.isActive = true
        await search(model, "cotizacion")
        #expect(await index.cachedCount == 2)

        model.isActive = false
        await model.meetings.indexTask?.value
        #expect(await index.cachedCount == 0)
        #expect(model.meetings.filtered.isEmpty, "the answer is gone with the index")
    }
}
