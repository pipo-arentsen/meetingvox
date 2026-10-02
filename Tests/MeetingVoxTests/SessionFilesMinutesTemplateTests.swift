import Foundation
import Testing
@testable import MeetingVox

@Suite struct SessionFilesMinutesTemplateTests {
    private func folder(_ meta: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-template-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(meta.utf8).write(to: dir.appendingPathComponent(SessionFiles.meta))
        return dir
    }

    @Test func settingNilRemovesTheKeyAndKeepsTheOthers() throws {
        let dir = try folder(#"{"minutes_template": "daily", "ambito": "trabajo", "custom": {"a": 1}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        try SessionFiles.setChosenMinutesTemplate(nil, in: dir)
        #expect(SessionFiles.chosenMinutesTemplate(in: dir) == nil)
        let text = String(decoding: try Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta)), as: UTF8.self)
        #expect(!text.contains("minutes_template"))
        #expect(text.contains("trabajo") && text.contains("custom"))
    }

    @Test func settingAnIdStillWritesIt() throws {
        let dir = try folder(#"{"ambito": "trabajo"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        try SessionFiles.setChosenMinutesTemplate("daily", in: dir)
        #expect(SessionFiles.chosenMinutesTemplate(in: dir) == "daily")
    }

    @Test func removingFromAMissingMetaThrowsAndWritesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meetingvox-no-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) { try SessionFiles.setChosenMinutesTemplate(nil, in: dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(SessionFiles.meta).path))
    }
}
