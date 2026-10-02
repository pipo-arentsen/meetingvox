import Foundation
import Testing
@testable import MeetingVox

/// Calendar link: the linked event's title shows wherever a
/// session is named, its names are searchable (with or without a summary), the
/// index keeps its "(sin resumen)" line, and "Quitar evento del calendario"
/// removes the key. `resumen.json` is never touched.
@MainActor @Suite struct CalendarDisplayTests {
    private let utc = TimeZone(identifier: "UTC")!
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func record(
        title: String = "Weekly Roadmap", organizer: String? = "Persona Organizadora", names: [String] = ["Persona Invitada", "Otra Persona"]
    ) -> CalendarEventRecord {
        CalendarEventRecord(
            snapshot: CalendarFixtures.snapshot(
                title: title,
                organizer: organizer.map { CalendarFixtures.person($0, email: "organizadora@example.com") },
                attendees: names.map { CalendarFixtures.person($0, email: "\($0.lowercased().replacingOccurrences(of: " ", with: "."))@example.com") }
                    + [CalendarFixtures.person("Yo Mismo", email: "me@example.com", isSelf: true)]),
            matchedAt: CalendarFixtures.at(1))
    }

    private func summary(_ title: String = "Resumen del sprint") -> MeetingSummary {
        MeetingSummary(
            title: title, summary: "Se vio el alcance.", client: nil, topics: [], participants: [],
            source: .transcript, model: "m", generatedAt: date("2026-09-24T11:00:00Z"))
    }

    private func entry(summary: MeetingSummary? = nil, event: CalendarEventRecord? = nil) -> MeetingEntry {
        var e = MeetingEntry(
            dir: URL(fileURLWithPath: "/root/2026.09.24-1053"), started: date("2026-09-24T10:53:00Z"),
            durationSeconds: 1800, app: "teams", summary: summary, hasMinutes: false, hasTranscript: true)
        e.calendarEvent = event
        return e
    }

    // MARK: - MeetingEntry reads the key

    @Test func meetingEntryReadsTheCalendarEventFromMeta() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-caldisplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONSerialization.data(withJSONObject: ["started": "2026-09-24T10:53:00Z"]).write(to: dir.appendingPathComponent("meta.json"))
        #expect(MeetingEntry.load(dir).calendarEvent == nil)
        try SessionFiles.setCalendarEvent(record(), in: dir)
        #expect(MeetingEntry.load(dir).calendarEvent == record())
        try JSONSerialization.data(withJSONObject: ["calendar_event": "garbage"]).write(to: dir.appendingPathComponent("meta.json"))
        #expect(MeetingEntry.load(dir).calendarEvent == nil, "malformed = no link")
    }

    // MARK: - Titles

    @Test func rowAndHeaderTitleCalendarWinsOverSummary() {
        let e = entry(summary: summary(), event: record())
        let header = DetailHeader.make(entry: e, type: .noMinutes, templates: [], timeZone: utc)
        #expect(header.title == "Weekly Roadmap")
        #expect(MeetingRowMeta.title(summaryTitle: "Resumen del sprint", calendarTitle: "Weekly Roadmap") == "Weekly Roadmap")
    }

    @Test func aLinkedSessionWithoutSummaryShowsTheCalendarTitle() {
        let e = entry(event: record())
        #expect(DetailHeader.make(entry: e, type: .noMinutes, templates: [], timeZone: utc).title == "Weekly Roadmap")
    }

    @Test func blankCalendarTitleFallsBackAndNoEventKeepsToday() {
        #expect(MeetingRowMeta.title(summaryTitle: "Resumen", calendarTitle: "  ") == "Resumen")
        #expect(MeetingRowMeta.title(summaryTitle: "Resumen") == "Resumen")
        #expect(MeetingRowMeta.title(summaryTitle: nil) == Textos.Principal.sinResumenFila)
        let plain = DetailHeader.make(entry: entry(summary: summary()), type: .noMinutes, templates: [], timeZone: utc)
        #expect(plain.title == "Resumen del sprint")
    }

    @Test func sessionLabelUsesTheCalendarTitleThenSummaryThenHeader() {
        func text(calendar: String?, title: String?) -> String {
            SessionLabel.text(
                summaryTitle: title, calendarTitle: calendar, started: date("2026-09-24T10:53:00Z"),
                ended: date("2026-09-24T11:05:00Z"), durationSeconds: nil, folder: "f", timeZone: utc)
        }
        #expect(text(calendar: "Weekly Roadmap", title: "Resumen") == "Weekly Roadmap")
        #expect(text(calendar: nil, title: "Resumen") == "Resumen")
        #expect(text(calendar: "  ", title: "Resumen") == "Resumen")
        #expect(text(calendar: "Weekly Roadmap", title: nil) == "Weekly Roadmap")
        #expect(text(calendar: nil, title: nil) == "Jue 24 sep · 10:53–11:05 (12 min)")
    }

    @Test func sessionLabelCutsALongCalendarTitle() {
        let long = String(repeating: "x", count: 80)
        let label = SessionLabel.text(
            summaryTitle: nil, calendarTitle: long, started: nil, ended: nil, durationSeconds: nil, folder: "f", timeZone: utc)
        #expect(label.count == SessionLabel.maxLength)
        #expect(label.hasSuffix("…"))
    }

    @Test func tasksListTheMeetingUnderTheCalendarTitle() {
        var e = entry(
            summary: MeetingSummary(
                title: "Resumen", summary: "x", client: nil, topics: [], participants: [], source: .transcript,
                model: "m", generatedAt: date("2026-09-24T11:00:00Z"),
                tasks: [MeetingTask(who: "Participante 1", what: "Enviar acta", when: nil)]),
            event: record())
        #expect(TaskAggregator.build([e]).first?.meetingTitle == "Weekly Roadmap")
        e.calendarEvent = nil
        #expect(TaskAggregator.build([e]).first?.meetingTitle == "Resumen")
    }

    // MARK: - indice.md

    @Test func indexShowsTheCalendarTitleForALinkedSessionWithoutSummaryAndKeepsSinResumen() {
        let text = IndexRenderer.render(entries: [entry(event: record())], now: date("2026-09-24T13:30:00Z"), timeZone: utc)
        #expect(text.contains("**Weekly Roadmap**"))
        #expect(text.contains("(sin resumen)"))
    }

    @Test func indexTitleWithSummaryIsTheCalendarOne() {
        let text = IndexRenderer.render(
            entries: [entry(summary: summary(), event: record())], now: date("2026-09-24T13:30:00Z"), timeZone: utc)
        #expect(text.contains("**Weekly Roadmap**"))
        #expect(!text.contains("Resumen del sprint"))
        #expect(!text.contains("(sin resumen)"))
    }

    @Test func indexWithoutEventIsUnchanged() {
        let withSummary = IndexRenderer.render(entries: [entry(summary: summary())], now: date("2026-09-24T13:30:00Z"), timeZone: utc)
        #expect(withSummary.contains("**Resumen del sprint**"))
        let bare = IndexRenderer.render(entries: [entry()], now: date("2026-09-24T13:30:00Z"), timeZone: utc)
        #expect(bare.contains("(sin resumen)"))
        #expect(!bare.contains("**"))
    }

    // MARK: - Search

    private func search(_ query: String, _ entries: [MeetingEntry]) -> [MeetingEntry] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return MeetingFilter.apply(entries, query: query, client: nil, range: .any, now: date("2026-09-24T12:00:00Z"), calendar: cal)
    }

    @Test func filterMatchesInviteeOrganizerAndTitleWithAndWithoutSummary() {
        let linked = entry(event: record())
        let withSummary = entry(summary: summary(), event: record())
        for query in ["invitada", "Organizadora", "roadmap", "invitada otra"] {
            #expect(search(query, [linked]).count == 1, "\(query), no summary")
            #expect(search(query, [withSummary]).count == 1, "\(query), with summary")
        }
        #expect(search("invitada", [entry()]).isEmpty)
    }

    @Test func emailsAreNotSearchable() {
        let e = entry(event: record())
        #expect(search("example", [e]).isEmpty)
        #expect(search("persona.invitada", [e]).isEmpty)
        // A participant whose "name" is just an address stays unsearchable too.
        let odd = entry(event: record(names: ["p7@example.com"]))
        #expect(search("p7", [odd]).isEmpty)
    }

    @Test func fullTextIndexFindsCalendarNamesWithoutSummary() async {
        let e = entry(event: record())
        let index = FullTextIndex()
        let result = await index.search(query: "invitada", entries: [e])
        #expect(result.matches == [e.dir])
        #expect(result.hits[e.dir] == nil, "metadata match, no snippet")
        #expect(await index.search(query: "example", entries: [e]).matches.isEmpty)
    }

    // MARK: - Unlink

    @Test func overflowOffersUnlinkOnlyWhenLinked() {
        func overflow(_ linked: Bool) -> [DetailActions.OverflowItem] {
            DetailActions.build(DetailActions.Input(
                hasTranscript: true, hasTranscriptMD: true, hasMinutes: false, minutesOwed: false, manualMinutes: [],
                templates: [], minutesUnavailableReason: nil, memory: nil, memoryInFlight: false,
                defaultBank: nil, otherBanks: [], hasCalendarEvent: linked)).overflow
        }
        #expect(!overflow(false).contains { $0.kind == .unlinkCalendar })
        let item = overflow(true).first { $0.kind == .unlinkCalendar }
        #expect(item?.title == "Quitar evento del calendario")
        #expect(item?.isEnabled == true)
    }

    private func linkedSession() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-caldisplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["started": "2026-09-24T10:53:00Z", "ambito": "trabajo"])
            .write(to: dir.appendingPathComponent("meta.json"))
        try SessionFiles.setCalendarEvent(record(), in: dir)
        return dir
    }

    @Test func unlinkRemovesTheKeyKeepsTheRestReindexesAndReloads() async throws {
        let dir = try linkedSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        let summaryBytes = Data("{\"keep\": true}".utf8)
        try summaryBytes.write(to: dir.appendingPathComponent("resumen.json"))
        var reindexed = 0
        let model = SessionDetailModel(inputs: { .none }, load: { d, _, _ in SessionDetailData(dir: d) })
        model.commands.reindex = { reindexed += 1 }
        var listReloads = 0
        model.onListNeedsReload = { listReloads += 1 }
        await model.select(dir).value

        model.perform(.unlinkCalendar, dir: dir)

        #expect(SessionFiles.calendarEvent(in: dir) == nil)
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json"))) as? [String: Any])
        #expect(json["ambito"] as? String == "trabajo")
        #expect(json["calendar_event"] is NSNull)
        #expect(reindexed == 1)
        #expect(listReloads == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent("resumen.json")) == summaryBytes)
        #expect(model.notice(for: dir) == nil)
    }

    @Test func aFailedUnlinkSaysSoAndDoesNotReindex() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meetingvox-caldisplay-missing-\(UUID().uuidString)")
        var reindexed = 0
        let model = SessionDetailModel(inputs: { .none }, load: { d, _, _ in SessionDetailData(dir: d) })
        model.commands.reindex = { reindexed += 1 }
        model.perform(.unlinkCalendar, dir: dir)
        #expect(reindexed == 0)
        #expect(model.notice(for: dir) == Textos.Sesiones.quitarEventoFallo)
    }
}
