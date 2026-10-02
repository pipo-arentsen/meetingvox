import Foundation
import Testing
@testable import MeetingVox

@Suite struct MeetingEntryTests {
    private func tempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeJSON(_ object: [String: Any], to url: URL) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try! data.write(to: url)
    }

    @Test func loadsFullMetaAndSummary() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1030")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJSON([
            "started": "2026-09-24T10:30:00Z",
            "duration_seconds": 1800,
            "meeting_app": "teams",
            "files": ["mic": "mic.caf"],
        ], to: dir.appendingPathComponent(SessionFiles.meta))
        writeJSON([
            "title": "Kickoff",
            "summary": "Se revisó el alcance.",
            "client": "Proveedor",
            "topics": ["alcance"],
            "participants": ["Participante 1"],
            "source": "transcript",
            "model": "openai/gpt-4o-mini",
            "generated_at": "2026-09-24T11:00:00Z",
        ], to: dir.appendingPathComponent(SessionFiles.summaryJSON))
        try SessionFiles.writeMarker(SessionFiles.transcriptJSON, in: dir)
        try SessionFiles.writeMarker(SessionFiles.minutes, in: dir)

        let entry = MeetingEntry.load(dir)

        #expect(entry.dir == dir)
        #expect(entry.started == ISO8601DateFormatter().date(from: "2026-09-24T10:30:00Z"))
        #expect(entry.durationSeconds == 1800)
        #expect(entry.app == "teams")
        #expect(entry.summary?.title == "Kickoff")
        #expect(entry.hasTranscript == true)
        #expect(entry.hasMinutes == true)
    }

    @Test func loadReadsTheBackfillFactsFromTheRawFiles() throws {
        let root = tempRoot()
        func session(_ name: String, summary: [String: Any]?, tasksError: Bool = false) throws -> MeetingEntry {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let summary { writeJSON(summary, to: dir.appendingPathComponent(SessionFiles.summaryJSON)) }
            if tasksError { try SessionFiles.writeMarker(SessionFiles.tasksError, in: dir) }
            return MeetingEntry.load(dir)
        }
        let legacy = try session("a", summary: ["title": "T", "summary": "S"])
        #expect(legacy.tasksBackfillFacts.hasSummary && !legacy.tasksBackfillFacts.hasTasksKey)
        // A malformed `tasks` decodes as nil but the key is there: never extracted over.
        let malformed = try session("b", summary: ["title": "T", "summary": "S", "tasks": "nope"])
        #expect(malformed.summary?.tasks == nil && malformed.tasksBackfillFacts.hasTasksKey)
        // Readable object that does not decode as a summary is still a summary file for the backfill.
        let bare = try session("c", summary: ["x": 1])
        #expect(bare.summary == nil && bare.tasksBackfillFacts.hasSummary)
        let failed = try session("d", summary: ["title": "T", "summary": "S"], tasksError: true)
        #expect(failed.tasksBackfillFacts.tasksError)
        #expect(!session_("e", root).tasksBackfillFacts.hasSummary)
    }

    private func session_(_ name: String, _ root: URL) -> MeetingEntry {
        let dir = root.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return MeetingEntry.load(dir)
    }

    @Test func noResumenJSONYieldsNilSummary() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1030")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJSON(["started": "2026-09-24T10:30:00Z"], to: dir.appendingPathComponent(SessionFiles.meta))

        let entry = MeetingEntry.load(dir)

        #expect(entry.summary == nil)
        #expect(entry.hasMinutes == false)
    }

    @Test func malformedResumenJSONYieldsNilSummaryWithoutThrowing() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1030")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJSON(["started": "2026-09-24T10:30:00Z"], to: dir.appendingPathComponent(SessionFiles.meta))
        try "not json".data(using: .utf8)!.write(to: dir.appendingPathComponent(SessionFiles.summaryJSON))

        let entry = MeetingEntry.load(dir)

        #expect(entry.summary == nil)
    }

    @Test func missingMetaFieldsFallBackToNilDurationAndApp() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1030")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJSON(["started": "2026-09-24T10:30:00Z"], to: dir.appendingPathComponent(SessionFiles.meta))

        let entry = MeetingEntry.load(dir)

        #expect(entry.durationSeconds == nil)
        #expect(entry.app == nil)
    }

    @Test func missingMetaJSONFallsBackToFolderNameDate() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1030")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // No meta.json at all.

        let entry = MeetingEntry.load(dir)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "en_US_POSIX").map { _ in TimeZone.current } ?? .current
        let expected = entry.started
        #expect(expected != nil)
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone.current, from: try #require(expected)
        )
        #expect(comps.year == 2026)
        #expect(comps.month == 9)
        #expect(comps.day == 24)
        #expect(comps.hour == 10)
        #expect(comps.minute == 30)
    }

    @Test func minutesPendingMarkerIsReflectedWhenNoMinutesFileExists() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1030")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try SessionFiles.writeMarker(SessionFiles.minutesPending, in: dir)

        let entry = MeetingEntry.load(dir)

        #expect(entry.minutesPending == true)
        #expect(entry.minutesFailed == false)
        #expect(entry.hasMinutes == false)
    }

    @Test func minutesErrorMarkerIsReflectedWhenNoMinutesFileExists() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1030")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try SessionFiles.writeMarker(SessionFiles.minutesError, in: dir)

        let entry = MeetingEntry.load(dir)

        #expect(entry.minutesFailed == true)
        #expect(entry.minutesPending == false)
        #expect(entry.hasMinutes == false)
    }

    @Test func noMinutesMarkersYieldsNeitherPendingNorFailed() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1030")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let entry = MeetingEntry.load(dir)

        #expect(entry.minutesPending == false)
        #expect(entry.minutesFailed == false)
    }

    @Test func unknownAppIDPassesThroughUnchanged() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1030")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJSON([
            "started": "2026-09-24T10:30:00Z",
            "meeting_app": "some-unknown-app",
        ], to: dir.appendingPathComponent(SessionFiles.meta))

        let entry = MeetingEntry.load(dir)

        #expect(entry.app == "some-unknown-app")
    }

    @Test func readsAmbitoEndedAndBothTemplateIDs() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1053")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJSON([
            "started": "2026-09-24T10:53:00Z",
            "ended": "2026-09-24T11:05:00Z",
            "duration_seconds": 720,
            "ambito": "personal",
            "minutes_template": "  familiar ",
        ], to: dir.appendingPathComponent(SessionFiles.meta))
        let header = MinutesCoordinator.provenance(
            model: "openai/gpt-4o-mini", templateID: "general",
            generatedAt: ISO8601DateFormatter().date(from: "2026-09-24T11:10:00Z")!, chunked: false
        )
        try Data((header + "\n\n# Minuta de reunión\n").utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes))

        let entry = MeetingEntry.load(dir)

        #expect(entry.ambito == .personal)
        #expect(entry.ended == ISO8601DateFormatter().date(from: "2026-09-24T11:05:00Z"))
        #expect(entry.metaTemplateID == "familiar")
        #expect(entry.minutesTemplateID == "general")
    }

    @Test func unknownOrMalformedValuesDegradeToNil() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1053")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJSON([
            "started": "2026-09-24T10:53:00Z", "ended": "ayer", "ambito": "Trabajo", "minutes_template": "   ",
        ], to: dir.appendingPathComponent(SessionFiles.meta))
        try Data("# Minuta sin encabezado\n".utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes))

        let entry = MeetingEntry.load(dir)

        #expect(entry.ambito == nil)
        #expect(entry.ended == nil)
        #expect(entry.metaTemplateID == nil)
        #expect(entry.minutesTemplateID == nil)
        #expect(Ambito(metaValue: 3) == nil)
        #expect(Ambito(metaValue: nil) == nil)
        #expect(Ambito(metaValue: "profesional") == .profesional)
    }

    @Test func noMinutesMeansNoHeaderTemplate() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026.09.24-1053")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJSON(["started": "2026-09-24T10:53:00Z"], to: dir.appendingPathComponent(SessionFiles.meta))
        // A manual minuta.<id>.md is not the session's minutes.
        let header = MinutesCoordinator.provenance(model: "m", templateID: "daily", generatedAt: Date(), chunked: false)
        try Data((header + "\n").utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes(templateID: "daily")))

        #expect(MeetingEntry.load(dir).minutesTemplateID == nil)
    }

    @Test func headerParsingMatchesTheProvenanceLineOnly() {
        let line = MinutesCoordinator.provenance(model: "a/b", templateID: "uno-a-uno", generatedAt: Date(), chunked: true)
        #expect(MeetingEntry.templateID(fromMinutesHeader: line + "\n\n# Reunión 1:1") == "uno-a-uno")
        #expect(MeetingEntry.templateID(fromMinutesHeader: "# Minuta\n" + line) == nil)
        #expect(MeetingEntry.templateID(fromMinutesHeader: "<!-- quill minutes · model: m · generated_at: x -->") == nil)
        #expect(MeetingEntry.templateID(fromMinutesHeader: "<!-- quill minutes · template:  · chunked: no -->") == nil)
        #expect(MeetingEntry.templateID(fromMinutesHeader: "") == nil)
    }

    // MARK: - Pipeline markers and tracks (main window)

    private func sessionDir(_ root: URL) throws -> URL {
        let dir = root.appendingPathComponent("2026.09.24-1053")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJSON(["started": "2026-09-24T10:53:00Z"], to: dir.appendingPathComponent(SessionFiles.meta))
        return dir
    }

    @Test func minutesStateFollowsMarkerPrecedencePendingDoneFailedAbsent() throws {
        let dir = try sessionDir(tempRoot())
        #expect(MeetingEntry.load(dir).minutesState == .absent)

        try SessionFiles.writeMarker(SessionFiles.minutesError, in: dir)
        #expect(MeetingEntry.load(dir).minutesState == .failed)

        try SessionFiles.writeMarker(SessionFiles.minutes, in: dir)
        #expect(MeetingEntry.load(dir).minutesState == .done)

        try SessionFiles.writeMarker(SessionFiles.minutesPending, in: dir)
        #expect(MeetingEntry.load(dir).minutesState == .pending)
    }

    @Test func minutesStateAgreesWithSettlementFacts() throws {
        // The scan replaces a per-row `Facts.read`, so it must not drift from
        // the `SessionSettlement` marker precedence.
        let combos: [[String]] = [
            [], [SessionFiles.minutesError], [SessionFiles.minutes], [SessionFiles.minutesPending],
            [SessionFiles.minutes, SessionFiles.minutesError],
            [SessionFiles.minutesPending, SessionFiles.minutesError],
        ]
        for markers in combos {
            let dir = try sessionDir(tempRoot())
            for marker in markers { try SessionFiles.writeMarker(marker, in: dir) }
            let facts = SessionSettlement.Facts.read(
                dir, authPaused: false, config: ConfigValues(raw: [:]), hasHindsightToken: { false }
            )
            #expect(MeetingEntry.load(dir).minutesState == facts.minutes, "markers: \(markers)")
        }
    }

    @Test func summaryStateFollowsTheSameMarkerPrecedence() throws {
        let dir = try sessionDir(tempRoot())
        #expect(MeetingEntry.load(dir).summaryState == .absent)

        try SessionFiles.writeMarker(SessionFiles.summaryError, in: dir)
        #expect(MeetingEntry.load(dir).summaryState == .failed)

        try SessionFiles.writeMarker(SessionFiles.summaryJSON, in: dir)
        #expect(MeetingEntry.load(dir).summaryState == .done)

        try SessionFiles.writeMarker(SessionFiles.summaryPending, in: dir)
        #expect(MeetingEntry.load(dir).summaryState == .pending)
    }

    @Test func tracksAreTheKeysOfMetaFiles() throws {
        let root = tempRoot()
        let both = try sessionDir(root)
        writeJSON(
            ["started": "2026-09-24T10:53:00Z", "files": ["mic": "mic.caf", "system": "system.caf"]],
            to: both.appendingPathComponent(SessionFiles.meta)
        )
        let micOnly = root.appendingPathComponent("2026.09.24-1153")
        try FileManager.default.createDirectory(at: micOnly, withIntermediateDirectories: true)
        writeJSON(["files": ["mic": "mic.caf"]], to: micOnly.appendingPathComponent(SessionFiles.meta))

        #expect(MeetingEntry.load(both).tracks == ["mic", "system"])
        #expect(MeetingEntry.load(micOnly).tracks == ["mic"])
    }

    @Test func missingOrMalformedFilesMeansNoTracks() throws {
        let dir = try sessionDir(tempRoot())
        #expect(MeetingEntry.load(dir).tracks.isEmpty)

        writeJSON(["files": "nope"], to: dir.appendingPathComponent(SessionFiles.meta))
        #expect(MeetingEntry.load(dir).tracks.isEmpty)
    }
}
