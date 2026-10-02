import Foundation
import Testing
@testable import MeetingVox

@Suite struct SummaryTasksMergeTests {
    private let legacy = #"""
    {"client":"Proveedor","generated_at":"2026-09-01T10:00:00Z","model":"m/x","participants":["Participante 1","Participante 2"],"source":"minutes","summary":"Resumen.\nDos líneas.","title":"Kickoff / ñandú","topics":["alcance","plazos"],"custom_key":{"nested":[1,2,{"a":null}]}}
    """#

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let tasks = [
        MeetingTask(who: "Participante 1", what: "Enviar oferta", when: "lunes"),
        MeetingTask(who: nil, what: "Revisar contrato", when: nil),
    ]

    @Test func neverOverwritesAnExistingCountry() throws {
        let withCountry = #"{"title":"T","country":"Chile"}"#
        let merged = try SummaryTasksMerge.merge(existing: Data(withCountry.utf8), tasks: tasks, country: "Alemania")
        #expect(try object(merged)["country"] as? String == "Chile")
        let blank = #"{"title":"T","country":"  "}"#
        let filled = try SummaryTasksMerge.merge(existing: Data(blank.utf8), tasks: tasks, country: "Alemania")
        #expect(try object(filled)["country"] as? String == "Alemania")
    }

    @Test func addsOnlyTasksAndCountryLeavingEveryOtherKeyValueEqual() throws {
        let before = try object(Data(legacy.utf8))
        let merged = try SummaryTasksMerge.merge(existing: Data(legacy.utf8), tasks: tasks, country: "Alemania")
        var after = try object(merged)

        let addedTasks = try #require(after.removeValue(forKey: "tasks") as? [[String: Any]])
        #expect(after.removeValue(forKey: "country") as? String == "Alemania")
        #expect(NSDictionary(dictionary: after).isEqual(to: before))

        #expect(addedTasks.count == 2)
        #expect(addedTasks[0]["who"] as? String == "Participante 1")
        #expect(addedTasks[0]["what"] as? String == "Enviar oferta")
        #expect(addedTasks[0]["when"] as? String == "lunes")
        #expect(addedTasks[1]["who"] == nil)
        #expect(addedTasks[1]["what"] as? String == "Revisar contrato")
    }

    @Test func emptyTasksAreWrittenAsAnEmptyArray() throws {
        let merged = try SummaryTasksMerge.merge(existing: Data(legacy.utf8), tasks: [], country: nil)
        let after = try object(merged)
        #expect((after["tasks"] as? [Any])?.isEmpty == true)
        #expect(after["country"] == nil)
    }

    @Test func nilCountryKeepsAnExistingCountry() throws {
        let existing = #"{"title":"T","country":"Chile"}"#
        let after = try object(SummaryTasksMerge.merge(existing: Data(existing.utf8), tasks: [], country: nil))
        #expect(after["country"] as? String == "Chile")
    }

    @Test func refusesWhenATasksKeyAlreadyExists() throws {
        for existing in [#"{"title":"T","tasks":[]}"#, #"{"title":"T","tasks":"nope"}"#, #"{"title":"T","tasks":null}"#] {
            #expect(throws: SummaryTasksMerge.MergeError.alreadyHasTasks) {
                try SummaryTasksMerge.merge(existing: Data(existing.utf8), tasks: [], country: nil)
            }
        }
    }

    @Test func refusesANonObjectFile() {
        #expect(throws: SummaryTasksMerge.MergeError.notAnObject) {
            try SummaryTasksMerge.merge(existing: Data("[1,2]".utf8), tasks: [], country: nil)
        }
        #expect(throws: SummaryTasksMerge.MergeError.notAnObject) {
            try SummaryTasksMerge.merge(existing: Data("garbage".utf8), tasks: [], country: nil)
        }
    }

    @Test func mergedFileDecodesAsAMeetingSummaryWithTheNewFields() throws {
        let merged = try SummaryTasksMerge.merge(existing: Data(legacy.utf8), tasks: tasks, country: "Alemania")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(MeetingSummary.self, from: merged)
        #expect(summary.client == "Proveedor")
        #expect(summary.title == "Kickoff / ñandú")
        #expect(summary.tasks == tasks)
        #expect(summary.country == "Alemania")
    }
}

@Suite struct TasksBackfillTests {
    private func facts(
        summary: String? = #"{"title":"T"}"#, summaryPending: Bool = false, minutesPending: Bool = false,
        tasksError: Bool = false
    ) -> TasksBackfill.Facts {
        TasksBackfill.Facts(
            summaryObject: summary.flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            },
            summaryPending: summaryPending, minutesPending: minutesPending, tasksError: tasksError
        )
    }

    @Test func legacySummaryWithoutTasksKeyIsACandidate() {
        #expect(TasksBackfill.isCandidate(facts()))
    }

    @Test func absentOrUnreadableSummaryIsNotACandidate() {
        #expect(!TasksBackfill.isCandidate(facts(summary: nil)))
        #expect(!TasksBackfill.isCandidate(facts(summary: "[1]")))
    }

    @Test func anyRawTasksKeyIsNotACandidate() {
        #expect(!TasksBackfill.isCandidate(facts(summary: #"{"title":"T","tasks":[]}"#)))
        #expect(!TasksBackfill.isCandidate(facts(summary: #"{"title":"T","tasks":[{"what":"x"}]}"#)))
        // Malformed is still "extracted": never re-extracted over.
        #expect(!TasksBackfill.isCandidate(facts(summary: #"{"title":"T","tasks":"nope"}"#)))
        #expect(!TasksBackfill.isCandidate(facts(summary: #"{"title":"T","tasks":null}"#)))
    }

    @Test func pendingSummaryOrMinutesOrAFailedBackfillSkipTheSession() {
        #expect(!TasksBackfill.isCandidate(facts(summaryPending: true)))
        #expect(!TasksBackfill.isCandidate(facts(minutesPending: true)))
        #expect(!TasksBackfill.isCandidate(facts(tasksError: true)))
    }

    @Test func cancellationIsNeitherAContentNorAnEnvironmentFailure() {
        #expect(TasksBackfill.classify(CancellationError()) == .cancelled)
        #expect(TasksBackfill.classify(SummaryError.invalidJSON("x")) == .content)
        #expect(TasksBackfill.classify(OpenRouterError.unauthorized("key")) == .environment)
    }

    @Test func readReflectsTheFilesOnDisk() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", transcript: true, pending: false)
        #expect(!TasksBackfill.isCandidate(TasksBackfill.Facts.read(dir)))  // no resumen.json

        try Data(#"{"title":"T"}"#.utf8).write(to: dir.appendingPathComponent(SessionFiles.summaryJSON))
        #expect(TasksBackfill.isCandidate(TasksBackfill.Facts.read(dir)))

        try SessionFiles.writeMarker(SessionFiles.tasksError, in: dir)
        #expect(!TasksBackfill.isCandidate(TasksBackfill.Facts.read(dir)))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.tasksError))

        try SessionFiles.writeMarker(SessionFiles.summaryPending, in: dir)
        #expect(!TasksBackfill.isCandidate(TasksBackfill.Facts.read(dir)))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.summaryPending))

        try SessionFiles.writeMarker(SessionFiles.minutesPending, in: dir)
        #expect(!TasksBackfill.isCandidate(TasksBackfill.Facts.read(dir)))
    }

    @Test func markerNamesAreDistinctFromTheSummaryOnes() {
        #expect(SessionFiles.tasksPending == "tareas.pendiente")
        #expect(SessionFiles.tasksError == "tareas.error")
    }
}
