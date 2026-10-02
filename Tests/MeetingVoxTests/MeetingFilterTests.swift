import Foundation
import Testing
@testable import MeetingVox

@Suite struct MeetingFilterTests {
    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func entry(
        dir: String = "/root/session", started: Date? = nil, title: String = "Kickoff",
        summaryText: String = "Se revisó el alcance del proyecto.", client: String? = "Proveedor",
        topics: [String] = ["alcance"], participants: [String] = ["Participante 1"], hasSummary: Bool = true
    ) -> MeetingEntry {
        MeetingEntry(
            dir: URL(fileURLWithPath: dir), started: started, durationSeconds: 1800, app: nil,
            summary: hasSummary
                ? MeetingSummary(
                    title: title, summary: summaryText, client: client, topics: topics,
                    participants: participants, source: .transcript, model: "m",
                    generatedAt: date("2026-09-24T11:00:00Z")
                )
                : nil,
            hasMinutes: false, hasTranscript: true
        )
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func diacriticInsensitiveSearchMatches() {
        let entry = entry(summaryText: "Se habló de la conciliación bancaria.")
        let result = MeetingFilter.apply(
            [entry], query: "conciliacion", client: nil, range: .any,
            now: date("2026-09-24T12:00:00Z"), calendar: calendar
        )
        #expect(result.count == 1)
    }

    @Test func caseInsensitiveSearchMatches() {
        let entry = entry(title: "Kickoff Proveedor")
        let result = MeetingFilter.apply(
            [entry], query: "KICKOFF", client: nil, range: .any,
            now: date("2026-09-24T12:00:00Z"), calendar: calendar
        )
        #expect(result.count == 1)
    }

    @Test func multipleTokensRequireAllToMatch() {
        let matching = entry(title: "Kickoff Proveedor", client: "Proveedor")
        let nonMatching = entry(dir: "/root/other", title: "Sync semanal", client: "Otra empresa")
        let result = MeetingFilter.apply(
            [matching, nonMatching], query: "kickoff proveedor", client: nil, range: .any,
            now: date("2026-09-24T12:00:00Z"), calendar: calendar
        )
        #expect(result.map(\.dir) == [matching.dir])
    }

    @Test func clientFilterMatchesExactly() {
        let proveedor = entry(dir: "/root/a", client: "Proveedor")
        let other = entry(dir: "/root/b", client: "Otra empresa")
        let result = MeetingFilter.apply(
            [proveedor, other], query: "", client: "Proveedor", range: .any,
            now: date("2026-09-24T12:00:00Z"), calendar: calendar
        )
        #expect(result.map(\.dir) == [proveedor.dir])
    }

    @Test func last7DaysIncludesBoundaryExcludesOlder() {
        let now = date("2026-09-24T12:00:00Z")
        let withinBoundary = entry(dir: "/root/within", started: date("2026-09-17T12:00:00Z"))
        let tooOld = entry(dir: "/root/old", started: date("2026-09-17T00:00:00Z"))
        let result = MeetingFilter.apply(
            [withinBoundary, tooOld], query: "", client: nil, range: .last7Days, now: now, calendar: calendar
        )
        #expect(result.map(\.dir) == [withinBoundary.dir])
    }

    @Test func thisMonthExcludesPreviousMonth() {
        let now = date("2026-09-24T12:00:00Z")
        let thisMonth = entry(dir: "/root/this", started: date("2026-09-01T00:00:00Z"))
        let lastMonth = entry(dir: "/root/last", started: date("2026-08-31T23:59:00Z"))
        let result = MeetingFilter.apply(
            [thisMonth, lastMonth], query: "", client: nil, range: .thisMonth, now: now, calendar: calendar
        )
        #expect(result.map(\.dir) == [thisMonth.dir])
    }

    @Test func clientsListsUniqueSortedNonEmptyClients() {
        let entries = [
            entry(dir: "/root/a", client: "Zeta"),
            entry(dir: "/root/b", client: "Alfa"),
            entry(dir: "/root/c", client: "Zeta"),
            entry(dir: "/root/d", client: nil),
        ]
        #expect(MeetingFilter.clients(in: entries) == ["Alfa", "Zeta"])
    }

    private func typed(
        _ dir: String, minutes: Bool, header: String? = nil, meta: String? = nil, ambito: Ambito? = nil
    ) -> MeetingEntry {
        MeetingEntry(
            dir: URL(fileURLWithPath: dir), started: date("2026-09-24T10:00:00Z"), durationSeconds: 600, app: nil,
            summary: nil, hasMinutes: minutes, hasTranscript: true, ambito: ambito,
            metaTemplateID: meta, minutesTemplateID: header
        )
    }

    @Test func ambitoFilterMatchesTheValueOrUnclassified() {
        let entries = [
            typed("/r/a", minutes: false, ambito: .personal),
            typed("/r/b", minutes: false, ambito: .trabajo),
            typed("/r/c", minutes: false),
        ]
        func run(_ filter: AmbitoFilter) -> [String] {
            MeetingFilter.apply(
                entries, query: "", client: nil, range: .any, ambito: filter,
                now: date("2026-09-24T12:00:00Z"), calendar: calendar
            ).map(\.dir.lastPathComponent)
        }
        #expect(run(.all) == ["a", "b", "c"])
        #expect(run(.only(.personal)) == ["a"])
        #expect(run(.only(.profesional)) == [])
        #expect(run(.unclassified) == ["c"])
    }

    @Test func typeFilterMatchesTheResolvedType() {
        let entries = [
            typed("/r/familia", minutes: true, header: "familiar"),
            typed("/r/general", minutes: true, header: "familiar", meta: "general"),
            typed("/r/sin", minutes: false),
        ]
        func run(_ type: MeetingType?) -> [String] {
            MeetingFilter.apply(
                entries, query: "", client: nil, range: .any, type: type, knownTemplateIDs: ["familiar", "general"],
                now: date("2026-09-24T12:00:00Z"), calendar: calendar
            ).map(\.dir.lastPathComponent)
        }
        #expect(run(.template("familiar")) == ["familia"])
        #expect(run(.template("general")) == ["general"])
        #expect(run(.noMinutes) == ["sin"])
        #expect(run(nil).count == 3)
    }

    @Test func ambitoTypeAndSearchCombineWithAnd() {
        var match = entry(dir: "/r/match", title: "Revisión del calendario", client: nil)
        match.ambito = .personal
        var otherAmbito = entry(dir: "/r/trabajo", title: "Revisión del calendario", client: nil)
        otherAmbito.ambito = .trabajo
        var otherText = entry(dir: "/r/otro", title: "Presupuesto", client: nil)
        otherText.ambito = .personal

        let result = MeetingFilter.apply(
            [match, otherAmbito, otherText], query: "revision", client: nil, range: .any,
            ambito: .only(.personal), type: .noMinutes,
            now: date("2026-09-24T12:00:00Z"), calendar: calendar
        )
        #expect(result.map(\.dir.lastPathComponent) == ["match"])
    }

    @Test func typesListTemplatesByLabelThenUnknownThenNoMinutes() {
        let entries = [
            typed("/r/1", minutes: true, header: "general"),
            typed("/r/2", minutes: true, header: "familiar"),
            typed("/r/3", minutes: true),
            typed("/r/4", minutes: false),
            typed("/r/5", minutes: true, header: "familiar"),
        ]
        #expect(MeetingFilter.types(in: entries, templates: [FactoryTemplates.general, FactoryTemplates.familiar])
            == [.template("general"), .template("familiar"), .unknown, .noMinutes])
        #expect(MeetingFilter.types(in: [typed("/r/4", minutes: false)], templates: []) == [.noMinutes])
    }

    // MARK: - Full-text matches (A2)

    @Test func noFullTextSetLeavesTheMetadataSearchUnchanged() {
        let withTitle = entry(dir: "/root/a", title: "Kickoff")
        let without = entry(dir: "/root/b", title: "Otro")
        let result = MeetingFilter.apply(
            [withTitle, without], query: "kickoff", client: nil, range: .any, fullTextMatches: nil,
            now: date("2026-09-24T12:00:00Z"), calendar: calendar
        )
        #expect(result.map(\.dir.path) == ["/root/a"])
    }

    @Test func aFullTextSetAddsTranscriptOnlyHitsToTheMetadataOnes() {
        let metadataHit = entry(dir: "/root/a", title: "Kickoff")
        let transcriptHit = entry(dir: "/root/b", title: "Otro")
        let miss = entry(dir: "/root/c", title: "Nada")
        let result = MeetingFilter.apply(
            [metadataHit, transcriptHit, miss], query: "kickoff", client: nil, range: .any,
            fullTextMatches: [transcriptHit.dir],
            now: date("2026-09-24T12:00:00Z"), calendar: calendar
        )
        #expect(result.map(\.dir.path) == ["/root/a", "/root/b"])
    }

    @Test func theFullTextSetNeverWidensPastTheOtherFilters() {
        let hit = entry(dir: "/root/b", client: "Otra")
        let result = MeetingFilter.apply(
            [hit], query: "zzz", client: "Proveedor", range: .any, fullTextMatches: [hit.dir],
            now: date("2026-09-24T12:00:00Z"), calendar: calendar
        )
        #expect(result.isEmpty)
    }

    @Test func anEmptyQueryIgnoresTheFullTextSet() {
        let a = entry(dir: "/root/a")
        let result = MeetingFilter.apply(
            [a], query: "", client: nil, range: .any, fullTextMatches: [],
            now: date("2026-09-24T12:00:00Z"), calendar: calendar
        )
        #expect(result.count == 1)
    }

    @Test func haystackTextIsTheSearchedMetadata() {
        let e = entry(title: "Kickoff", summaryText: "resumen", client: "Proveedor", topics: ["t1"], participants: ["Participante 1"])
        #expect(MeetingFilter.haystackText(e) == "Kickoff resumen Proveedor t1 Participante 1")
        #expect(MeetingFilter.haystackText(entry(hasSummary: false)) == "")
    }
}
