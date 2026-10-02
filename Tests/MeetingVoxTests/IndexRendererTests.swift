import Foundation
import Testing
@testable import MeetingVox

@Suite struct IndexRendererTests {
    private let tz = TimeZone(identifier: "America/Santiago")!

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func summary(
        title: String = "Kickoff", client: String? = "Proveedor", topics: [String] = ["alcance"]
    ) -> MeetingSummary {
        MeetingSummary(
            title: title, summary: "Se revisó el alcance del proyecto.", client: client,
            topics: topics, participants: ["Participante 1"], source: .transcript,
            model: "openai/gpt-4o-mini", generatedAt: date("2026-09-24T11:00:00Z")
        )
    }

    @Test func groupsByMonthNewestFirst() throws {
        let september = MeetingEntry(
            dir: URL(fileURLWithPath: "/root/2026.09.24-1030"), started: date("2026-09-24T13:30:00Z"),
            durationSeconds: 1800, app: "teams", summary: summary(), hasMinutes: true, hasTranscript: true
        )
        let august = MeetingEntry(
            dir: URL(fileURLWithPath: "/root/2026.08.10-0900"), started: date("2026-08-10T12:00:00Z"),
            durationSeconds: 900, app: nil, summary: summary(title: "Sync"), hasMinutes: false, hasTranscript: true
        )

        let rendered = IndexRenderer.render(entries: [august, september], now: date("2026-09-24T13:30:00Z"), timeZone: tz)

        let septemberRange = try #require(rendered.range(of: "## Septiembre 2026"))
        let augustRange = try #require(rendered.range(of: "## Agosto 2026"))
        #expect(septemberRange.lowerBound < augustRange.lowerBound)
    }

    @Test func showsSinResumenWhenSummaryMissing() throws {
        let entry = MeetingEntry(
            dir: URL(fileURLWithPath: "/root/2026.09.24-1030"), started: date("2026-09-24T13:30:00Z"),
            durationSeconds: 1800, app: nil, summary: nil, hasMinutes: false, hasTranscript: true
        )

        let rendered = IndexRenderer.render(entries: [entry], now: date("2026-09-24T13:30:00Z"), timeZone: tz)

        #expect(rendered.contains("(sin resumen)"))
    }

    @Test func omitsEmptyClientAndTopicsLabels() throws {
        let entry = MeetingEntry(
            dir: URL(fileURLWithPath: "/root/2026.09.24-1030"), started: date("2026-09-24T13:30:00Z"),
            durationSeconds: 1800, app: nil, summary: summary(client: nil, topics: []),
            hasMinutes: false, hasTranscript: true
        )

        let rendered = IndexRenderer.render(entries: [entry], now: date("2026-09-24T13:30:00Z"), timeZone: tz)

        #expect(!rendered.contains("Temas:"))
        #expect(!rendered.contains("Proveedor"))
    }

    @Test func linksAreRelativeToRoot() throws {
        let entry = MeetingEntry(
            dir: URL(fileURLWithPath: "/root/2026.09.24-1030"), started: date("2026-09-24T13:30:00Z"),
            durationSeconds: 1800, app: nil, summary: summary(), hasMinutes: true, hasTranscript: true
        )

        let rendered = IndexRenderer.render(entries: [entry], now: date("2026-09-24T13:30:00Z"), timeZone: tz)

        #expect(rendered.contains("(2026.09.24-1030)"))
        #expect(!rendered.contains("/root/"))
    }

    @Test func minutaLinkOnlyWhenPresent() throws {
        let withMinutes = MeetingEntry(
            dir: URL(fileURLWithPath: "/root/2026.09.24-1030"), started: date("2026-09-24T13:30:00Z"),
            durationSeconds: 1800, app: nil, summary: summary(), hasMinutes: true, hasTranscript: true
        )
        let withoutMinutes = MeetingEntry(
            dir: URL(fileURLWithPath: "/root/2026.09.24-1100"), started: date("2026-09-24T14:00:00Z"),
            durationSeconds: 1800, app: nil, summary: summary(), hasMinutes: false, hasTranscript: true
        )

        let renderedWith = IndexRenderer.render(entries: [withMinutes], now: date("2026-09-24T13:30:00Z"), timeZone: tz)
        let renderedWithout = IndexRenderer.render(entries: [withoutMinutes], now: date("2026-09-24T13:30:00Z"), timeZone: tz)

        #expect(renderedWith.contains("minuta.md"))
        #expect(!renderedWithout.contains("minuta.md"))
    }
}
