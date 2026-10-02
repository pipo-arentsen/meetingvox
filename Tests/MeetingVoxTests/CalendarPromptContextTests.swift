import Foundation
import Testing
@testable import MeetingVox

/// Calendar link: with a linked event the minutes and summary
/// prompts carry the event title and the invitee names (never emails), with the
/// "invited is not attended" caveat. The no-event bytes are pinned by
/// `CalendarPromptGoldenTests`.
@Suite struct CalendarPromptContextTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let started = Date(timeIntervalSince1970: 1_790_172_300)

    private func record(title: String = "Weekly Roadmap", names: [String] = ["Persona Invitada", "Otra Persona"]) -> CalendarEventRecord {
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

    private func info(_ event: CalendarEventRecord?) -> SessionInfo {
        SessionInfo(
            name: "2026.09.23-1405", started: started, durationSeconds: 3_900,
            calendarTitle: event?.title, invitees: event.map(CalendarInvitees.offMac) ?? [])
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-calprompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Minutes

    @Test func metadataWithAnEventCarriesTitleNamesAndTheCaveat() {
        let text = PromptBuilder.metadata(info(record()), timeZone: utc)
        #expect(text.hasPrefix("Datos de la sesión:\n- Nombre de la sesión: 2026.09.23-1405"))
        #expect(text.contains("Weekly Roadmap"))
        #expect(text.contains("Persona Organizadora, Persona Invitada, Otra Persona"))
        #expect(!text.contains("Yo Mismo"))
        #expect(!text.contains("@"))
        #expect(text.contains(MinutesPrompts.invitadosAviso))
        #expect(MinutesPrompts.invitadosAviso.contains("no implica"))
    }

    @Test func eventWithoutInviteesStillCarriesItsTitle() {
        let alone = record(names: [])
        let lonely = SessionInfo(name: "s", started: nil, durationSeconds: nil, calendarTitle: alone.title, invitees: [])
        let text = PromptBuilder.metadata(lonely)
        #expect(text.contains("Weekly Roadmap"))
        #expect(text.contains(MinutesPrompts.invitadosAviso))
    }

    @Test func everyMinutesCallThatSendsContextCarriesTheBlock() {
        let i = info(record())
        let lines = [TranscriptLine(startMs: 0, endMs: 1_000, speaker: "me", text: "Hola")]
        let calls = [
            PromptBuilder.userPrompt(info: i, lines: lines, timeZone: utc),
            PromptBuilder.partialUserPrompt(info: i, part: 1, of: 2, lines: lines, timeZone: utc),
            PromptBuilder.consolidationUserPrompt(info: i, notes: ["n"], timeZone: utc),
            PromptBuilder.reductionUserPrompt(info: i, notes: ["n"], firstPart: 1, total: 2, timeZone: utc),
        ]
        for call in calls {
            #expect(call.contains("Weekly Roadmap"))
            #expect(call.contains("Persona Invitada"))
            #expect(call.contains(MinutesPrompts.invitadosAviso))
        }
    }

    @Test func thirtyNamedInviteesAreCappedAtTwentyFive() {
        let names = (1...30).map { "Persona \($0)" }
        let text = PromptBuilder.metadata(info(record(names: names)), timeZone: utc)
        #expect(text.contains("Persona 24"))   // organizer + 24 attendees = 25
        #expect(!text.contains("Persona 25"))
        #expect(!text.contains("Persona 30"))
    }

    @Test func sessionInfoReadsTheEventAtJobTime() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONSerialization.data(withJSONObject: ["started": "2026-09-23T14:05:00Z", "duration_seconds": 3900])
            .write(to: dir.appendingPathComponent("meta.json"))
        let before = SessionInfo.read(from: dir)
        #expect(before.calendarTitle == nil)
        #expect(before.invitees.isEmpty)
        try SessionFiles.setCalendarEvent(record(), in: dir)
        let after = SessionInfo.read(from: dir)
        #expect(after.calendarTitle == "Weekly Roadmap")
        #expect(after.invitees == ["Persona Organizadora", "Persona Invitada", "Otra Persona"])
        #expect(after.name == before.name && after.started == before.started)
    }

    // MARK: - Summary

    @Test func summaryUserPromptWithAnEventCarriesTheBlock() {
        let i = info(record())
        let text = SummaryPrompts.userPrompt(
            sessionName: "s1", content: "[00:00] Yo: Hola", calendarTitle: i.calendarTitle, invitees: i.invitees)
        #expect(text.hasPrefix("Sesión: s1\n"))
        #expect(text.hasSuffix("Contenido de la reunión:\n[00:00] Yo: Hola"))
        #expect(text.contains("Weekly Roadmap"))
        #expect(text.contains("Persona Organizadora, Persona Invitada, Otra Persona"))
        #expect(text.contains(MinutesPrompts.invitadosAviso))
        #expect(!text.contains("@"))
    }

    @Test func summaryUserPromptWithoutTitleOrNamesIsUnchanged() {
        #expect(
            SummaryPrompts.userPrompt(sessionName: "s", content: "c", calendarTitle: nil, invitees: [])
                == SummaryPrompts.userPrompt(sessionName: "s", content: "c"))
        #expect(
            SummaryPrompts.userPrompt(sessionName: "s", content: "c", calendarTitle: "  ", invitees: [])
                == SummaryPrompts.userPrompt(sessionName: "s", content: "c"))
    }
}
