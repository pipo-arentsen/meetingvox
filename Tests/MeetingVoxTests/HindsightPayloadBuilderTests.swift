import Foundation
import Testing
@testable import MeetingVox

private let mexico = TimeZone(identifier: "America/Mexico_City")!
private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

private let sampleSummary = MeetingSummary(
    title: "Kickoff", summary: "Resumen breve.", client: "Proveedor", topics: ["alcance", "precios"],
    participants: ["Participante 1", "Participante 3"], source: .minutes, model: "m/x", generatedAt: iso("2026-09-23T15:30:00Z")
)

private let sampleMinutes = "# Minuta\n\n## Asistentes\n- Yo: Persona Anfitriona\n- Otros: Participante 1, Participante 3\n\n## Acuerdos\n- Acuerdo secreto con miting vox."

private func sampleInput(
    minutes: String? = sampleMinutes,
    summary: MeetingSummary? = sampleSummary,
    ended: Date? = iso("2026-09-23T15:10:00Z"),
    chosenTemplate: String? = "comercial",
    engine: String? = "parakeet",
    model: String? = "parakeet-tdt-0.6b-v3",
    segments: [TranscriptInput.Segment] = [
        .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Hola, hablemos de miting vox"),
        .init(speaker: "me", start_ms: 2000, end_ms: 3000, text: "y del plan"),
        .init(speaker: "them", start_ms: 61_000, end_ms: 62_000, text: "Buenas"),
    ]
) -> HindsightSessionInput {
    HindsightSessionInput(
        name: "2026.09.23-1405", started: iso("2026-09-23T14:05:00Z"), ended: ended, durationSeconds: 3900,
        chosenTemplate: chosenTemplate, summary: summary, minutes: minutes,
        transcriptEngine: engine, transcriptModel: model, segments: segments
    )
}

private func sampleOptions(
    ownerDescription: String = "quien grabó la reunión",
    glossary: [GlossaryEntry] = [GlossaryEntry(term: "MeetingVox", variants: ["miting vox"])],
    forcedAt: Date? = nil
) -> HindsightBuildOptions {
    HindsightBuildOptions(
        ownerName: "Usuario", ownerDescription: ownerDescription, glossary: glossary, timeZone: mexico,
        configTemplate: "general",
        templateName: { ["comercial": "Llamada comercial", "general": "Minuta general", "daily": "Daily"][$0] },
        forcedAt: forcedAt
    )
}

private func json(_ payload: HindsightPayload) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
}

private func item(_ payload: HindsightPayload) throws -> [String: Any] {
    let items = try #require(try json(payload)["items"] as? [[String: Any]])
    #expect(items.count == 1)
    return try #require(items.first)
}

private func build(_ input: HindsightSessionInput = sampleInput(), _ options: HindsightBuildOptions = sampleOptions()) throws -> HindsightPayload {
    try #require(try HindsightPayloadBuilder.build(input, options))
}

@Suite struct HindsightPayloadBuilderTests {
    // MARK: Content

    @Test func turnsMergeConsecutiveSpeakersWithAbsoluteTimeAndGlossary() {
        let turns = HindsightPayloadBuilder.turns(
            sampleInput().segments, started: iso("2026-09-23T14:05:00Z"), ownerName: "Usuario",
            glossary: [GlossaryEntry(term: "MeetingVox", variants: ["miting vox"])], timeZone: mexico
        )
        #expect(turns == [
            HindsightTurn(role: "Usuario", content: "Hola, hablemos de MeetingVox y del plan", timestamp: "2026-09-23T08:05:00-06:00"),
            HindsightTurn(role: "Otros", content: "Buenas", timestamp: "2026-09-23T08:06:01-06:00"),
        ])
    }

    @Test func emptySegmentsAreSkippedAndDoNotSplitATurn() {
        let turns = HindsightPayloadBuilder.turns(
            [
                .init(speaker: "me", start_ms: 0, end_ms: nil, text: "uno"),
                .init(speaker: "them", start_ms: 500, end_ms: nil, text: "   "),
                .init(speaker: "me", start_ms: 1000, end_ms: nil, text: " dos "),
            ],
            started: iso("2026-09-23T14:05:00Z"), ownerName: "Yo", glossary: [], timeZone: mexico
        )
        #expect(turns.map(\.content) == ["uno dos"])
    }

    @Test func unknownSpeakerIdPassesThroughAsRole() {
        let turns = HindsightPayloadBuilder.turns(
            [.init(speaker: "x", start_ms: 0, end_ms: nil, text: "hola")],
            started: iso("2026-09-23T14:05:00Z"), ownerName: "Usuario", glossary: [], timeZone: mexico
        )
        #expect(turns.map(\.role) == ["x"])
    }

    @Test func contentIsDeterministicSortedJSONWithoutEscapedSlashes() throws {
        let content = try HindsightPayloadBuilder.content([
            HindsightTurn(role: "Usuario", content: "a/b", timestamp: "2026-09-23T08:05:00-06:00"),
        ])
        #expect(content == #"[{"content":"a/b","role":"Usuario","timestamp":"2026-09-23T08:05:00-06:00"}]"#)
        #expect(try item(build())["content"] as? String == (try HindsightPayloadBuilder.content(
            HindsightPayloadBuilder.turns(sampleInput().segments, started: iso("2026-09-23T14:05:00Z"), ownerName: "Usuario",
                                          glossary: sampleOptions().glossary, timeZone: mexico)
        )))
    }

    // MARK: Request shape

    @Test func oneItemWithStableDocumentIDTagsScopesAndNoEntities() throws {
        let p = try build()
        let body = try json(p)
        let it = try item(p)
        #expect(body["async"] as? Bool == true)
        #expect(body["operation_id"] as? String == p.operationID)
        #expect(it["document_id"] as? String == "mv-2026.09.23-1405")
        #expect(p.documentID == "mv-2026.09.23-1405")
        #expect(it["timestamp"] as? String == "2026-09-23T08:05:00-06:00")
        #expect(it["tags"] as? [String] == ["fuente:meetingvox", "tipo:transcripcion", "plantilla:comercial", "cliente:proveedor"])
        #expect(it["observation_scopes"] as? String == "shared")
        #expect(it["update_mode"] as? String == "replace")
        #expect(it["entities"] == nil)
        #expect(HindsightPayloadBuilder.isCurrentDocumentID("mv-2026.09.23-1405"))
        #expect(!HindsightPayloadBuilder.isCurrentDocumentID("quill-2026.09.23-1405-transcripcion"))
    }

    @Test func metadataHasExactlyTheV2Keys() throws {
        #expect(try item(build())["metadata"] as? [String: String] == [
            "titulo": "Kickoff",
            "fecha": "2026-09-23",
            "hora_inicio": "08:05",
            "hora_fin": "09:10",
            "duracion_min": "65",
            "zona_horaria": "America/Mexico_City",
            "plantilla": "comercial",
            "asistentes": "Persona Anfitriona, Participante 1, Participante 3",
            "motor_transcripcion": "parakeet",
            "modelo_transcripcion": "parakeet-tdt-0.6b-v3",
            "modelo_resumen": "m/x",
        ])
    }

    @Test func blankOrMissingMetadataIsOmitted() throws {
        let p = try build(sampleInput(minutes: nil, summary: nil, ended: nil, chosenTemplate: nil, engine: " ", model: nil))
        let it = try item(p)
        #expect(it["metadata"] as? [String: String] == [
            "fecha": "2026-09-23", "hora_inicio": "08:05", "duracion_min": "65", "zona_horaria": "America/Mexico_City",
        ])
        #expect(it["tags"] as? [String] == ["fuente:meetingvox", "tipo:transcripcion"])
    }

    @Test func templateResolutionFollowsV1Precedence() {
        let options = sampleOptions()
        #expect(HindsightPayloadBuilder.templateID(sampleInput(chosenTemplate: "daily"), options) == "daily")
        #expect(HindsightPayloadBuilder.templateID(sampleInput(chosenTemplate: "borrada"), options) == "general")
        #expect(HindsightPayloadBuilder.templateID(sampleInput(chosenTemplate: nil), options) == "general")
        #expect(HindsightPayloadBuilder.templateID(sampleInput(minutes: nil, chosenTemplate: nil), options) == nil)
        let badConfig = HindsightBuildOptions(
            ownerName: "Usuario", ownerDescription: "", glossary: [], timeZone: mexico,
            configTemplate: "../fuera", templateName: { $0 == "general" ? "Minuta general" : nil }
        )
        #expect(HindsightPayloadBuilder.templateID(sampleInput(chosenTemplate: nil), badConfig) == "general")
    }

    @Test func minutesAndSummaryTextNeverLeave() throws {
        let body = String(decoding: try build().body, as: UTF8.self)
        #expect(!body.contains("Acuerdo secreto"))
        #expect(!body.contains("Resumen breve"))
        #expect(!body.contains("alcance"))
    }

    // MARK: Context

    @Test func contextWithTitleEndAndOwnerDescription() throws {
        #expect(try item(build())["context"] as? String
            == "Transcripción de la reunión \"Kickoff\" del 2026-09-23, 08:05–09:10. La pista Usuario es quien grabó la reunión; la pista Otros agrupa a todos los demás participantes.")
    }

    @Test func contextWithoutTitleWithoutEndAndWithoutDescription() throws {
        let p = try build(sampleInput(summary: nil, ended: nil), sampleOptions(ownerDescription: ""))
        #expect(try item(p)["context"] as? String
            == "Transcripción de la reunión del 2026-09-23, 08:05. La pista Usuario es Usuario; la pista Otros agrupa a todos los demás participantes.")
    }

    // MARK: pais / cliente tags

    private func summary(client: String?, country: String?) -> MeetingSummary {
        MeetingSummary(
            title: "Kickoff", summary: "Resumen breve.", client: client, topics: [], participants: [],
            source: .minutes, model: "m/x", generatedAt: iso("2026-09-23T15:30:00Z"), country: country
        )
    }

    @Test func clientAndCountryBecomeNormalizedTagsAfterTheTemplate() throws {
        let p = try build(sampleInput(summary: summary(client: "Cliente Principal", country: "México")))
        #expect(try item(p)["tags"] as? [String] == [
            "fuente:meetingvox", "tipo:transcripcion", "plantilla:comercial", "pais:mexico", "cliente:cliente-principal",
        ])
    }

    @Test func tagsAreOmittedWhenClientOrCountryIsMissingOrHasNoLetters() throws {
        let onlyCountry = try build(sampleInput(summary: summary(client: nil, country: "Chile")))
        #expect(try item(onlyCountry)["tags"] as? [String]
            == ["fuente:meetingvox", "tipo:transcripcion", "plantilla:comercial", "pais:chile"])
        let junk = try build(sampleInput(summary: summary(client: "¿?", country: "  ")))
        #expect(try item(junk)["tags"] as? [String] == ["fuente:meetingvox", "tipo:transcripcion", "plantilla:comercial"])
    }

    @Test func changingTheTagsChangesTheBodyButNeverTheContentHash() throws {
        let a = try build(sampleInput(summary: summary(client: "Proveedor", country: "Alemania")))
        let b = try build(sampleInput(summary: summary(client: "Proveedor Ltda", country: "Suiza")))
        #expect(a.contentHash == b.contentHash)
        #expect(a.bodyHash != b.bodyHash)
        #expect(a.operationID != b.operationID)
        // Neither client nor country leaks into the transcript content or the metadata.
        let text = try #require(try item(a)["content"] as? String)
        #expect(!text.contains("Proveedor") && !text.contains("Alemania"))
        let metadata = try #require(try item(a)["metadata"] as? [String: String])
        #expect(!metadata.values.contains { $0.contains("Proveedor") || $0.contains("Alemania") })
    }

    // MARK: Hashes and operation ids

    @Test func contentHashIgnoresMetadataMinutesAndSummary() throws {
        let a = try build()
        let b = try build(sampleInput(minutes: "# Otra minuta", summary: nil, chosenTemplate: "daily"))
        #expect(a.contentHash == b.contentHash)
        #expect(a.bodyHash != b.bodyHash)
        #expect(a.contentHash == HindsightPayloadBuilder.contentHash(try #require(try item(a)["content"] as? String)))
        let c = try build(sampleInput(segments: [.init(speaker: "me", start_ms: 0, end_ms: nil, text: "otra cosa")]))
        #expect(c.contentHash != a.contentHash)
    }

    @Test func normalOperationIDIsStableAndDerivedFromTheBody() throws {
        let a = try build()
        let b = try build()
        #expect(a.body == b.body)
        #expect(a.operationID == b.operationID)
        #expect(a.operationID == HindsightPayloadBuilder.operationID(forHash: a.bodyHash))
    }

    @Test func forcedOperationIDIsNewAndDependsOnTheDate() throws {
        let normal = try build()
        let forced1 = try build(sampleInput(), sampleOptions(forcedAt: iso("2026-09-24T12:00:00Z")))
        let forced1Again = try build(sampleInput(), sampleOptions(forcedAt: iso("2026-09-24T12:00:00Z")))
        let forced2 = try build(sampleInput(), sampleOptions(forcedAt: iso("2026-09-24T12:05:00Z")))
        #expect(forced1.operationID != normal.operationID)
        #expect(forced1.operationID == forced1Again.operationID)
        #expect(forced1.operationID != forced2.operationID)
        #expect(forced1.bodyHash == normal.bodyHash)
        #expect(forced1.contentHash == normal.contentHash)
        #expect(forced1.operationID == HindsightPayloadBuilder.forcedOperationID(bodyHash: normal.bodyHash, forcedAt: iso("2026-09-24T12:00:00Z")))
    }

    @Test func operationIDKnownVector() {
        #expect(HindsightPayloadBuilder.operationID(forHash: String(repeating: "ab", count: 32))
            == "abababab-abab-5bab-abab-abababababab")
    }

    @Test func emptyTranscriptBuildsNothing() throws {
        #expect(try HindsightPayloadBuilder.build(
            sampleInput(segments: [.init(speaker: "me", start_ms: 0, end_ms: nil, text: "  ")]), sampleOptions()
        ) == nil)
    }

    // MARK: Reading a folder

    @Test func readsASessionFolder() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try Data("# Minuta".utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes))
        let input = try HindsightSessionInput.read(from: dir)
        #expect(input.name == "2026.09.23-1405")
        #expect(input.started == iso("2026-09-23T14:05:00Z"))
        #expect(input.durationSeconds == 3900)
        #expect(input.minutes == "# Minuta")
        #expect(input.transcriptEngine == "fake")
        #expect(input.segments.count == 2)
    }

    @Test func missingOrCorruptTranscriptThrows() throws {
        let fixture = try SessionFixture()
        let missing = try fixture.session("a", transcript: false, pending: false)
        #expect(throws: HindsightSessionInput.ReadError.transcriptMissing) { try HindsightSessionInput.read(from: missing) }
        let corrupt = try fixture.session("2026.09.23-1405", pending: false)
        try Data("{".utf8).write(to: corrupt.appendingPathComponent(SessionFiles.transcriptJSON))
        #expect(throws: HindsightSessionInput.ReadError.self) { try HindsightSessionInput.read(from: corrupt) }
    }

    // MARK: Glossary

    @Test func aCorrectedTranscriptIsNeverReplacedAgain() throws {
        var input = sampleInput(segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "MeetingVox y miting vox", text_raw: "miting vox y miting vox"),
        ])
        input.glossaryApplied = true
        let payload = try #require(try HindsightPayloadBuilder.build(input, sampleOptions()))
        let item = try #require((try json(payload)["items"] as? [[String: Any]])?.first)
        #expect((item["content"] as? String)?.contains("MeetingVox y miting vox") == true)
    }

    @Test func aLegacyTranscriptGetsOnlyTheFlaggedEntries() throws {
        let input = sampleInput(segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "miting vox y kafca")])
        let options = sampleOptions(glossary: [
            GlossaryEntry(term: "MeetingVox", variants: ["miting vox"]),
            GlossaryEntry(term: "Kafka", variants: ["kafca"], transcript: false),
        ])
        let payload = try #require(try HindsightPayloadBuilder.build(input, options))
        let item = try #require((try json(payload)["items"] as? [[String: Any]])?.first)
        #expect((item["content"] as? String)?.contains("MeetingVox y kafca") == true)
    }

    @Test func exportGlossaryIsEmptyOnceAppliedAndFlaggedOtherwise() {
        let glossary = [
            GlossaryEntry(term: "MeetingVox", variants: ["miting vox"]),
            GlossaryEntry(term: "Kafka", variants: ["kafca"], transcript: false),
        ]
        #expect(HindsightPayloadBuilder.exportGlossary(glossary, glossaryApplied: true).isEmpty)
        #expect(HindsightPayloadBuilder.exportGlossary(glossary, glossaryApplied: false).map(\.term) == ["MeetingVox"])
    }

    @Test func readingATranscriptWithTextRawMarksItApplied() throws {
        let fixture = try SessionFixture()
        let legacy = try fixture.session("2026.09.23-1405", pending: false)
        #expect(try HindsightSessionInput.read(from: legacy).glossaryApplied == false)
        let corrected = try fixture.session("2026.09.23-1500", pending: false, text: "miting vox")
        _ = try TranscriptGlossary.reapply(in: corrected, glossary: [GlossaryEntry(term: "MeetingVox", variants: ["miting vox"])])
        #expect(try HindsightSessionInput.read(from: corrected).glossaryApplied)
    }
}
