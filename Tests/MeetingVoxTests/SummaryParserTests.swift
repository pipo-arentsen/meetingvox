import Foundation
import Testing
@testable import MeetingVox

@Suite struct SummaryParserTests {
    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func validJSON() throws -> String {
        try json([
            "title": "Kickoff Proveedor",
            "summary": "Se revisó el alcance del proyecto.\nSe acordó el cronograma.",
            "client": "Proveedor",
            "topics": ["alcance", "cronograma"],
            "participants": ["Participante 1", "Participante 2"],
        ])
    }

    @Test func parsesPlainJSON() throws {
        let fields = try SummaryParser.parse(validJSON())
        #expect(fields.title == "Kickoff Proveedor")
        #expect(fields.summary.contains("alcance del proyecto"))
        #expect(fields.client == "Proveedor")
        #expect(fields.topics == ["alcance", "cronograma"])
        #expect(fields.participants == ["Participante 1", "Participante 2"])
    }

    @Test func parsesJSONInsideFences() throws {
        let text = "```json\n\(try validJSON())\n```"
        let fields = try SummaryParser.parse(text)
        #expect(fields.title == "Kickoff Proveedor")
    }

    @Test func parsesJSONWrappedInProse() throws {
        let text = "Aquí está el resumen solicitado:\n\n\(try validJSON())\n\nEspero que sirva."
        let fields = try SummaryParser.parse(text)
        #expect(fields.title == "Kickoff Proveedor")
        #expect(fields.client == "Proveedor")
    }

    @Test func missingTitleThrowsInvalidJSON() throws {
        let text = try json(["summary": "algo"])
        #expect(throws: SummaryError.self) { try SummaryParser.parse(text) }
    }

    @Test func emptyTitleThrowsInvalidJSON() throws {
        let text = try json(["title": "   ", "summary": "algo"])
        #expect(throws: SummaryError.self) { try SummaryParser.parse(text) }
    }

    @Test func emptySummaryThrowsInvalidJSON() throws {
        let text = try json(["title": "T", "summary": "   "])
        #expect(throws: SummaryError.self) { try SummaryParser.parse(text) }
    }

    @Test func missingSummaryThrowsInvalidJSON() throws {
        let text = try json(["title": "T"])
        #expect(throws: SummaryError.self) { try SummaryParser.parse(text) }
    }

    @Test func titleAndSummaryAreClamped() throws {
        let longTitle = String(repeating: "a", count: 120)
        let longSummary = (0..<5).map { "línea \($0) " + String(repeating: "b", count: 100) }.joined(separator: "\n")
        let text = try json(["title": longTitle, "summary": longSummary])
        let fields = try SummaryParser.parse(text)
        #expect(fields.title.count == 80)
        #expect(fields.summary.count <= 280)
        #expect(!fields.summary.contains("línea 2"))
    }

    @Test func blankClientBecomesNil() throws {
        let text = try json(["title": "T", "summary": "S", "client": "   "])
        let fields = try SummaryParser.parse(text)
        #expect(fields.client == nil)
    }

    @Test func clientIsClampedTo80Characters() throws {
        let text = try json(["title": "T", "summary": "S", "client": String(repeating: "x", count: 200)])
        let fields = try SummaryParser.parse(text)
        #expect(fields.client?.count == SummaryParser.maxClientCharacters)
        #expect(SummaryParser.maxClientCharacters == 80)
    }

    @Test func topicsAreDedupedCaseInsensitiveAndCappedAtFive() throws {
        let text = try json([
            "title": "T", "summary": "S",
            "topics": ["Alcance", "alcance", "Cronograma", "riesgos", "presupuesto", "seguimiento", "extra"],
        ])
        let fields = try SummaryParser.parse(text)
        #expect(fields.topics == ["Alcance", "Cronograma", "riesgos", "presupuesto", "seguimiento"])
    }

    @Test func participantsAreCappedAtTen() throws {
        let names = (1...15).map { "Persona \($0)" }
        let text = try json(["title": "T", "summary": "S", "participants": names])
        let fields = try SummaryParser.parse(text)
        #expect(fields.participants.count == 10)
        #expect(fields.participants == Array(names.prefix(10)))
    }

    // MARK: - tasks + country

    @Test func repliesWithoutTasksKeyYieldNilTasksAndCountry() throws {
        let fields = try SummaryParser.parse(validJSON())
        #expect(fields.tasks == nil)
        #expect(fields.country == nil)
    }

    @Test func parsesTasksAndCountry() throws {
        let text = try json([
            "title": "T", "summary": "S", "country": "  México ",
            "tasks": [
                ["who": "Participante 1", "what": "Enviar la propuesta", "when": "viernes"],
                ["who": "Yo", "what": "Revisar el contrato", "when": NSNull()],
            ],
        ])
        let fields = try SummaryParser.parse(text)
        #expect(fields.country == "México")
        #expect(fields.tasks == [
            MeetingTask(who: "Participante 1", what: "Enviar la propuesta", when: "viernes"),
            MeetingTask(who: "Yo", what: "Revisar el contrato", when: nil),
        ])
    }

    @Test func emptyTasksArrayIsExtractedNone() throws {
        let fields = try SummaryParser.parse(json(["title": "T", "summary": "S", "tasks": []]))
        #expect(fields.tasks == [])
    }

    @Test func nonArrayTasksIsTreatedAsMissing() throws {
        let fields = try SummaryParser.parse(json(["title": "T", "summary": "S", "tasks": "ninguna"]))
        #expect(fields.tasks == nil)
    }

    @Test func blankWhatTasksAreDroppedAndBlankFieldsBecomeNil() throws {
        let text = try json([
            "title": "T", "summary": "S", "country": "  ",
            "tasks": [
                ["who": "Participante 1", "what": "   "],
                ["what": "Sin dueño", "who": "  ", "when": " "],
                ["who": "Participante 2"],
            ],
        ])
        let fields = try SummaryParser.parse(text)
        #expect(fields.country == nil)
        #expect(fields.tasks == [MeetingTask(who: nil, what: "Sin dueño", when: nil)])
    }

    @Test func taskCountIsCappedAtTwenty() throws {
        let many = (1...60).map { ["who": "Participante 1", "what": "Tarea \($0)"] }
        let fields = try SummaryParser.parse(json(["title": "T", "summary": "S", "tasks": many]))
        #expect(fields.tasks?.count == 20)
        #expect(fields.tasks?.first?.what == "Tarea 1")
    }

    @Test func taskAndCountryFieldsAreClamped() throws {
        let text = try json([
            "title": "T", "summary": "S", "country": String(repeating: "c", count: 90),
            "tasks": [[
                "who": String(repeating: "w", count: 90),
                "what": String(repeating: "a", count: 300),
                "when": String(repeating: "d", count: 90),
            ]],
        ])
        let fields = try SummaryParser.parse(text)
        let task = try #require(fields.tasks?.first)
        #expect(task.what.count == 200)
        #expect(task.who?.count == 60)
        #expect(task.when?.count == 40)
        #expect(fields.country?.count == 40)
    }

    @Test func parseTasksReadsATasksOnlyReply() throws {
        let text = try json(["tasks": [["who": "Participante 1", "what": "Llamar"]], "country": "Chile"])
        let result = try SummaryParser.parseTasks(text)
        #expect(result.tasks == [MeetingTask(who: "Participante 1", what: "Llamar", when: nil)])
        #expect(result.country == "Chile")
    }

    @Test func parseTasksAcceptsAnEmptyList() throws {
        let result = try SummaryParser.parseTasks(json(["tasks": [], "country": NSNull()]))
        #expect(result.tasks == [])
        #expect(result.country == nil)
    }

    @Test func parseTasksRejectsAReplyWithoutATasksArray() throws {
        #expect(throws: SummaryError.self) { try SummaryParser.parseTasks(json(["country": "Chile"])) }
        #expect(throws: SummaryError.self) { try SummaryParser.parseTasks("no json") }
    }
}

@Suite struct MeetingSummaryEncodingTests {
    @Test func encodesNilClientAsExplicitJSONNullRatherThanOmittingTheKey() throws {
        let summary = MeetingSummary(
            title: "T", summary: "S", client: nil, topics: [], participants: [],
            source: .transcript, model: "m/x", generatedAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"client\":null"))
    }

    @Test func decodingToleratesAnOmittedClientKey() throws {
        let json = #"{"title":"T","summary":"S","topics":[],"participants":[],"source":"transcript","model":"m/x","generated_at":"1970-01-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(MeetingSummary.self, from: Data(json.utf8))

        #expect(summary.client == nil)
    }

    // MARK: - schema (tasks + country)

    private func decode(_ json: String) throws -> MeetingSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingSummary.self, from: Data(json.utf8))
    }

    private func base(_ extra: String) -> String {
        #"{"title":"T","summary":"S","topics":[],"participants":[],"source":"transcript","model":"m/x","generated_at":"1970-01-01T00:00:00Z"\#(extra)}"#
    }

    @Test func legacyFileDecodesWithNeverExtractedTasksAndNoCountry() throws {
        let summary = try decode(base(""))
        #expect(summary.tasks == nil)
        #expect(summary.country == nil)
    }

    @Test func emptyTasksIsExtractedNone() throws {
        let summary = try decode(base(#","tasks":[]"#))
        #expect(summary.tasks == [])
    }

    @Test func decodesTasksAndCountry() throws {
        let summary = try decode(base(#","tasks":[{"who":"Participante 1","what":"Llamar","when":"lunes"},{"what":"Sin dueño"}],"country":"Chile""#))
        #expect(summary.tasks == [
            MeetingTask(who: "Participante 1", what: "Llamar", when: "lunes"),
            MeetingTask(who: nil, what: "Sin dueño", when: nil),
        ])
        #expect(summary.country == "Chile")
    }

    @Test func malformedTasksDecodeAsNilAndKeepTheSummary() throws {
        let summary = try decode(base(#","tasks":"nope","country":"Chile""#))
        #expect(summary.tasks == nil)
        #expect(summary.country == "Chile")
        #expect(summary.title == "T")
    }

    @Test func malformedTaskElementDecodesTasksAsNil() throws {
        let summary = try decode(base(#","tasks":[{"who":"Participante 1"}]"#))
        #expect(summary.tasks == nil)
    }

    @Test func malformedCountryDecodesAsNilAndKeepsTheSummary() throws {
        let summary = try decode(base(#","country":42,"tasks":[]"#))
        #expect(summary.country == nil)
        #expect(summary.tasks == [])
        #expect(summary.title == "T")
    }

    @Test func nilTasksAreOmittedAndEmptyTasksAreWritten() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func encoded(_ tasks: [MeetingTask]?) throws -> String {
            let summary = MeetingSummary(
                title: "T", summary: "S", client: nil, topics: [], participants: [],
                source: .transcript, model: "m/x", generatedAt: Date(timeIntervalSince1970: 0),
                tasks: tasks, country: nil
            )
            return try #require(String(data: encoder.encode(summary), encoding: .utf8))
        }
        #expect(try !encoded(nil).contains("\"tasks\""))
        #expect(try encoded([]).contains("\"tasks\":[]"))
    }

    @Test func tasksAndCountryRoundTrip() throws {
        let original = MeetingSummary(
            title: "T", summary: "S", client: "Proveedor", topics: ["a"], participants: ["Participante 1"],
            source: .minutes, model: "m/x", generatedAt: Date(timeIntervalSince1970: 0),
            tasks: [MeetingTask(who: "Yo", what: "Enviar", when: nil)], country: "Alemania"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try decode(String(decoding: encoder.encode(original), as: UTF8.self))
        #expect(decoded == original)
    }
}
