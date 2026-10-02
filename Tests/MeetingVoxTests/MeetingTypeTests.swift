import Foundation
import Testing
@testable import MeetingVox

@Suite struct MeetingTypeTests {
    private func entry(minutes: Bool, meta: String? = nil, header: String? = nil) -> MeetingEntry {
        MeetingEntry(
            dir: URL(fileURLWithPath: "/tmp/2026.09.24-1053"), started: nil, durationSeconds: nil, app: nil,
            summary: nil, hasMinutes: minutes, hasTranscript: true, metaTemplateID: meta, minutesTemplateID: header
        )
    }

    private let known: Set<String> = ["general", "familiar"]

    @Test func metaWinsWhenItsTemplateExists() {
        #expect(MeetingType.of(entry(minutes: true, meta: "familiar", header: "general"), knownTemplateIDs: known)
            == .template("familiar"))
    }

    @Test func aMetaTemplateThatNoLongerExistsFallsBackToTheHeader() {
        #expect(MeetingType.of(entry(minutes: true, meta: "borrada", header: "general"), knownTemplateIDs: known)
            == .template("general"))
    }

    @Test func aDeletedTemplateKnownOnlyFromMetaKeepsItsID() {
        #expect(MeetingType.of(entry(minutes: true, meta: "borrada"), knownTemplateIDs: known) == .template("borrada"))
    }

    @Test func invalidIDsAreIgnored() {
        #expect(MeetingType.of(entry(minutes: true, meta: "../x", header: "general"), knownTemplateIDs: known)
            == .template("general"))
        #expect(MeetingType.of(entry(minutes: true, header: ".oculta"), knownTemplateIDs: known) == .unknown)
    }

    @Test func minutesWithoutAnyTemplateAreUnknown() {
        #expect(MeetingType.of(entry(minutes: true), knownTemplateIDs: known) == .unknown)
    }

    @Test func noMinutesIsNoMinutesUnlessMetaChoseATemplate() {
        #expect(MeetingType.of(entry(minutes: false), knownTemplateIDs: known) == .noMinutes)
        // A header is only read with minutes; a stale value never counts.
        #expect(MeetingType.of(entry(minutes: false, header: "general"), knownTemplateIDs: known) == .noMinutes)
        // Order: meta.json first (e.g. minutes still pending).
        #expect(MeetingType.of(entry(minutes: false, meta: "familiar"), knownTemplateIDs: known) == .template("familiar"))
    }

    @Test func labelIsTheTemplateNameOrItsIDOnceDeleted() {
        #expect(MeetingType.template("familiar").label(templates: [FactoryTemplates.familiar]) == "Reunión familiar")
        #expect(MeetingType.template("borrada").label(templates: [FactoryTemplates.familiar]) == "borrada")
        #expect(MeetingType.unknown.label(templates: []) == Textos.Indice.sinPlantilla)
        #expect(MeetingType.noMinutes.label(templates: []) == Textos.Indice.sinMinuta)
        #expect(Ambito.allCases.map(\.label) == ["Trabajo", "Profesional", "Personal"])
    }
}
