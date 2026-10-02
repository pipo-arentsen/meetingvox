import Foundation
import Testing
@testable import MeetingVox

/// The detail header's text as pure data: title, meta line, ámbito, cliente
/// and the tracks chip.
@Suite("DetailHeader")
struct DetailHeaderTests {
    private let utc = TimeZone(identifier: "UTC")!
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func entry(
        title: String? = "Revisión sprint 14", client: String? = "Cliente B", app: String? = "teams",
        ambito: Ambito? = .trabajo, tracks: Set<String> = ["mic", "system"], hasMinutes: Bool = true
    ) -> MeetingEntry {
        let summary = title.map {
            MeetingSummary(
                title: $0, summary: "x", client: client, topics: [], participants: [],
                source: .minutes, model: "m", generatedAt: date("2026-09-24T12:00:00Z")
            )
        }
        var e = MeetingEntry(
            dir: URL(fileURLWithPath: "/fake/2026.09.24-1053"), started: date("2026-09-24T10:53:00Z"),
            durationSeconds: nil, app: app, summary: summary, hasMinutes: hasMinutes, hasTranscript: true
        )
        e.ended = date("2026-09-24T11:35:00Z")
        e.ambito = ambito
        e.tracks = tracks
        return e
    }

    private func make(_ e: MeetingEntry, type: MeetingType = .template("general")) -> DetailHeader {
        DetailHeader.make(entry: e, type: type, templates: [FactoryTemplates.general], timeZone: utc)
    }

    @Test func titleAndTheMetaLineWithDateAppAndTemplate() {
        let header = make(entry())
        #expect(header.title == "Revisión sprint 14")
        #expect(header.meta == "Jue 24 sep · 10:53–11:35 (42 min) · Teams · Plantilla: \(FactoryTemplates.general.nombre)")
    }

    @Test func aSessionWithoutSummaryIsUntitledAndAManualRecordingSaysSo() {
        let header = make(entry(title: nil, app: nil), type: .noMinutes)
        #expect(header.title == Textos.Principal.sinResumenFila)
        #expect(header.meta == "Jue 24 sep · 10:53–11:35 (42 min) · Grabación manual", "no template line without minutes")
    }

    @Test func aDeletedTemplateShowsItsIdAndUnknownMinutesShowNoTemplate() {
        #expect(make(entry(), type: .template("viejo")).meta.hasSuffix("Plantilla: viejo"))
        #expect(!make(entry(), type: .unknown).meta.contains("Plantilla"))
    }

    @Test func chipsAreAmbitoClientAndTheTracksThatWereRecorded() {
        let header = make(entry())
        #expect(header.ambito == .trabajo)
        #expect(header.client == "Cliente B")
        #expect(header.pistas == "\(Textos.Principal.pistaYo) · \(Textos.Principal.pistaOtros)")
    }

    @Test func aSingleTrackAndNoTrackAndNoClient() {
        #expect(make(entry(tracks: ["mic"])).pistas == Textos.Principal.pistaYo)
        #expect(make(entry(tracks: ["system"])).pistas == Textos.Principal.pistaOtros)
        #expect(make(entry(tracks: [])).pistas == nil)
        let bare = make(entry(client: "  ", ambito: nil))
        #expect(bare.client == nil, "a blank client shows no chip")
        #expect(bare.ambito == nil)
    }
}
