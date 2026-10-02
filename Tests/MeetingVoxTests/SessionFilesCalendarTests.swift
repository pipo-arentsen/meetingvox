import Foundation
import Testing
@testable import MeetingVox

@Suite struct SessionFilesCalendarTests {
    private func session(_ meta: [String: Any]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-calfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            .write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    private func raw(_ dir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func record(_ title: String = "Weekly", id: String = "e1") -> CalendarEventRecord {
        CalendarEventRecord(
            snapshot: CalendarFixtures.snapshot(id: id, title: title, attendees: [CalendarFixtures.person("Participante 1")]),
            matchedAt: CalendarFixtures.at(5))
    }

    @Test func writesTheEventAndKeepsEveryOtherKey() throws {
        let dir = try session(["started": "x", "ambito": "trabajo", "files": ["mic": "mic.caf"]])
        let wrote = try SessionFiles.setCalendarEvent(record(), in: dir)
        #expect(wrote)
        let json = try raw(dir)
        #expect(json["ambito"] as? String == "trabajo")
        #expect(json["started"] as? String == "x")
        #expect((json["files"] as? [String: String])?["mic"] == "mic.caf")
        #expect(SessionFiles.calendarEvent(in: dir) == record())
    }

    @Test func storedKeyHasNoNotesUrlOrLocation() throws {
        let dir = try session(["started": "x"])
        try SessionFiles.setCalendarEvent(record(), in: dir)
        let text = try String(contentsOf: dir.appendingPathComponent("meta.json"), encoding: .utf8)
        for forbidden in ["notes", "url\"", "location"] { #expect(!text.contains(forbidden)) }
    }

    @Test func ifAbsentNeverOverwritesAnExistingKey() throws {
        let dir = try session(["started": "x"])
        try SessionFiles.setCalendarEvent(record("First"), in: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        let wrote = try SessionFiles.setCalendarEvent(record("Second"), in: dir, ifAbsent: true)
        #expect(!wrote)
        #expect(try Data(contentsOf: dir.appendingPathComponent("meta.json")) == before)
        #expect(SessionFiles.calendarEvent(in: dir)?.title == "First")
    }

    @Test func ifAbsentWritesWhenTheKeyIsMissing() throws {
        let dir = try session(["started": "x"])
        let wrote = try SessionFiles.setCalendarEvent(record("Only"), in: dir, ifAbsent: true)
        #expect(wrote)
        #expect(SessionFiles.calendarEvent(in: dir)?.title == "Only")
    }

    @Test func plainSetReplacesAndNilRemovesKeepingOtherKeys() throws {
        let dir = try session(["started": "x", "ambito": "personal"])
        try SessionFiles.setCalendarEvent(record("First"), in: dir)
        try SessionFiles.setCalendarEvent(record("Second"), in: dir)
        #expect(SessionFiles.calendarEvent(in: dir)?.title == "Second")
        try SessionFiles.setCalendarEvent(nil, in: dir)
        let json = try raw(dir)
        #expect(json[SessionFiles.metaCalendarEventKey] is NSNull, "unlink writes an explicit null")
        #expect(json["ambito"] as? String == "personal")
        #expect(SessionFiles.calendarEvent(in: dir) == nil)
    }

    @Test func afterAnUnlinkTheFollowUpNeverRelinks() throws {
        let dir = try session(["started": "x"])
        try SessionFiles.setCalendarEvent(record("First"), in: dir)
        try SessionFiles.setCalendarEvent(nil, in: dir) // "Quitar evento" while the follow-up was pending
        let before = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        let wrote = try SessionFiles.setCalendarEvent(record("Late"), in: dir, ifAbsent: true)
        #expect(!wrote)
        #expect(try Data(contentsOf: dir.appendingPathComponent("meta.json")) == before)
        #expect(SessionFiles.calendarEvent(in: dir) == nil)
        #expect(MeetingEntry.load(dir).calendarEvent == nil)
    }

    @Test func missingMetaThrowsAndWritesNothing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-calfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try SessionFiles.setCalendarEvent(record(), in: dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path))
    }

    @Test func malformedValueReadsAsNoLink() throws {
        let dir = try session(["started": "x", "calendar_event": ["title": "  "]])
        #expect(SessionFiles.calendarEvent(in: dir) == nil)
        #expect(SessionFiles.calendarEvent(in: dir.appendingPathComponent("nope")) == nil)
    }
}
