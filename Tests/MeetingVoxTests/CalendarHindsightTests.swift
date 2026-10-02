import Foundation
import Testing
@testable import MeetingVox

/// Calendar link: a linked event changes the Hindsight
/// metadata (`titulo`, `asistentes`, the context sentence) and nothing else:
/// `content`, its hash and the operation ids never move, and no email is sent.
@Suite struct CalendarHindsightTests {
    private let mexico = TimeZone(identifier: "America/Mexico_City")!
    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private let minutes = "# Minuta\n\n## Asistentes\n- Yo: Persona Anfitriona\n- Otros: Participante 1, Participante 3\n"

    private func summary() -> MeetingSummary {
        MeetingSummary(
            title: "Kickoff", summary: "Resumen.", client: "Proveedor", topics: [], participants: [],
            source: .minutes, model: "m/x", generatedAt: iso("2026-09-23T15:30:00Z"))
    }

    private func event(title: String = "Weekly Roadmap", names: [String] = ["Persona Invitada", "Otra Persona"]) -> CalendarEventRecord {
        CalendarEventRecord(
            snapshot: CalendarFixtures.snapshot(
                title: title,
                organizer: CalendarFixtures.person("Persona Organizadora", email: "organizadora@example.com"),
                attendees: names.map {
                    CalendarFixtures.person($0, email: "\($0.lowercased().replacingOccurrences(of: " ", with: "."))@example.com")
                } + [
                    CalendarFixtures.person("Yo Mismo", email: "me@example.com", isSelf: true),
                    CalendarFixtures.person(nil, email: "ghost@example.com"),
                ]),
            matchedAt: CalendarFixtures.at(1))
    }

    private func input(
        event: CalendarEventRecord? = nil, summary: MeetingSummary? = nil, minutes: String? = nil
    ) -> HindsightSessionInput {
        HindsightSessionInput(
            name: "2026.09.23-1405", started: iso("2026-09-23T14:05:00Z"), ended: iso("2026-09-23T15:10:00Z"),
            durationSeconds: 3900, chosenTemplate: "general", summary: summary, minutes: minutes,
            transcriptEngine: "parakeet", transcriptModel: "m",
            segments: [
                .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Hola, hablemos del plan"),
                .init(speaker: "them", start_ms: 61_000, end_ms: 62_000, text: "Buenas"),
            ],
            calendarEvent: event)
    }

    private var options: HindsightBuildOptions {
        HindsightBuildOptions(
            ownerName: "Usuario", ownerDescription: "quien grabó la reunión", glossary: [], timeZone: mexico,
            configTemplate: "general", templateName: { ["general": "Minuta general"][$0] })
    }

    private func item(_ payload: HindsightPayload) throws -> [String: Any] {
        let body = try #require(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        return try #require((body["items"] as? [[String: Any]])?.first)
    }

    private func metadata(_ input: HindsightSessionInput) throws -> [String: String] {
        try #require(try item(build(input))["metadata"] as? [String: String])
    }

    private func build(_ input: HindsightSessionInput) throws -> HindsightPayload {
        try #require(try HindsightPayloadBuilder.build(input, options))
    }

    // MARK: - Metadata

    @Test func tituloComesFromTheEventWhenLinked() throws {
        let meta = try metadata(input(event: event(), summary: summary()))
        #expect(meta["titulo"] == "Weekly Roadmap")
    }

    @Test func tituloFallsBackToTheSummaryAndTheEventAloneIsEnough() throws {
        let plain = try metadata(input(summary: summary()))
        #expect(plain["titulo"] == "Kickoff")
        let noSummary = try metadata(input(event: event()))
        #expect(noSummary["titulo"] == "Weekly Roadmap")
        let blank = try metadata(input(event: event(title: "  "), summary: summary()))
        #expect(blank["titulo"] == "Kickoff")
    }

    @Test func asistentesPreferTheInviteeNamesOverTheMinutes() throws {
        let meta = try metadata(input(event: event(), minutes: minutes))
        #expect(meta["asistentes"] == "Persona Organizadora, Persona Invitada, Otra Persona")
    }

    @Test func asistentesKeepTheMinutesWhenTheEventHasNoUsableNames() throws {
        let alone = CalendarEventRecord(
            snapshot: CalendarFixtures.snapshot(title: "Solo", organizer: nil, attendees: [CalendarFixtures.person("Yo", isSelf: true)]),
            matchedAt: CalendarFixtures.at(1))
        let meta = try metadata(input(event: alone, minutes: minutes))
        #expect(meta["asistentes"] == "Persona Anfitriona, Participante 1, Participante 3")
        #expect(meta["titulo"] == "Solo")
    }

    @Test func noEventMetadataIsUnchanged() throws {
        let meta = try metadata(input(summary: summary(), minutes: minutes))
        #expect(meta["titulo"] == "Kickoff")
        #expect(meta["asistentes"] == "Persona Anfitriona, Participante 1, Participante 3")
    }

    @Test func theContextSentenceNamesTheEventTitle() throws {
        let withEvent = try #require(try item(build(input(event: event(), summary: summary())))["context"] as? String)
        #expect(withEvent.contains("\"Weekly Roadmap\""))
        #expect(!withEvent.contains("\"Kickoff\""))
        let plain = try #require(try item(build(input(summary: summary())))["context"] as? String)
        #expect(plain.contains("\"Kickoff\""))
    }

    // MARK: - Content never moves

    @Test func contentAndItsHashAreIdenticalWithAndWithoutAnEvent() throws {
        let plain = try build(input(summary: summary(), minutes: minutes))
        let linked = try build(input(event: event(), summary: summary(), minutes: minutes))
        #expect(try item(plain)["content"] as? String == (try item(linked)["content"] as? String))
        #expect(plain.contentHash == linked.contentHash)
        #expect(plain.documentID == linked.documentID)
        // The body does change (titulo/asistentes/context), and with it the
        // operation id, but a send is keyed on the content hash only.
        #expect(plain.bodyHash != linked.bodyHash)
    }

    @Test func noEmailAndNoCalendarWordsLeaveInThePayload() throws {
        let linked = try build(input(event: event(), summary: summary(), minutes: minutes))
        let text = String(decoding: linked.body, as: UTF8.self)
        #expect(!text.contains("@"))
        #expect(!text.contains("example.com"))
        let content = try #require(try item(linked)["content"] as? String)
        #expect(!content.contains("Weekly Roadmap"))
        #expect(!content.contains("Persona Invitada"))
    }

    // MARK: - Reading

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-calhs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func theSessionInputReadsTheEventFromMeta() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        #expect(try HindsightSessionInput.read(from: dir).calendarEvent == nil)
        try SessionFiles.setCalendarEvent(event(), in: dir)
        #expect(try HindsightSessionInput.read(from: dir).calendarEvent == event())
    }

    @Test func aSentSessionStaysSentWhenItGainsOrLosesAnEvent() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let opts = HindsightFacts.Options(ownerName: "Usuario", glossary: [], timeZone: mexico)
        let hash = HindsightPayloadBuilder.contentHash(try HindsightPayloadBuilder.content(
            HindsightPayloadBuilder.turns(
                try HindsightSessionInput.read(from: dir).segments, started: try HindsightSessionInput.read(from: dir).started,
                ownerName: "Usuario", glossary: [], timeZone: mexico)))
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1405", contentHash: hash, operationID: "o", sentAt: Date(timeIntervalSince1970: 0)),
            dir, SessionFiles.hindsightSent)
        #expect(HindsightFacts.read(dir, opts).isSentCurrent)
        try SessionFiles.setCalendarEvent(event(), in: dir)
        #expect(HindsightFacts.read(dir, opts).isSentCurrent, "gaining an event never re-queues a sent session")
        try SessionFiles.setCalendarEvent(nil, in: dir)
        #expect(HindsightFacts.read(dir, opts).isSentCurrent, "losing it neither")
    }
}
