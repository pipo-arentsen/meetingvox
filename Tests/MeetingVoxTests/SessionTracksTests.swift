import Foundation
import Testing
@testable import MeetingVox

/// `SessionTracks` reads which tracks a session has and where each starts
/// from meta.json, without touching the transcription coordinator's
/// own reader.
@Suite("SessionTracks")
struct SessionTracksTests {
    private func parse(_ json: String) -> [SessionTracks.Ref] {
        SessionTracks.parse(metaJSON: Data(json.utf8))
    }

    @Test func bothTracksWithOffsets() {
        let refs = parse(#"{"files": {"mic": "mic.caf", "system": "system.caf"}, "start_offset_ms": {"mic": 0, "system": 1200}}"#)
        #expect(refs == [
            SessionTracks.Ref(id: .mic, file: "mic.caf", offsetMs: 0),
            SessionTracks.Ref(id: .system, file: "system.caf", offsetMs: 1200),
        ])
    }

    @Test func aMissingOffsetDefaultsToZero() {
        let refs = parse(#"{"files": {"mic": "mic.caf"}}"#)
        #expect(refs == [SessionTracks.Ref(id: .mic, file: "mic.caf", offsetMs: 0)])
    }

    @Test func onlyTheTracksListedInFilesCount() {
        let refs = parse(#"{"files": {"system": "system.caf"}, "start_offset_ms": {"mic": 5, "system": 40}}"#)
        #expect(refs == [SessionTracks.Ref(id: .system, file: "system.caf", offsetMs: 40)])
    }

    @Test func malformedOrMissingMetaGivesNothing() {
        #expect(parse("not json").isEmpty)
        #expect(parse("[]").isEmpty)
        #expect(parse(#"{"files": "mic.caf"}"#).isEmpty)
        #expect(parse("{}").isEmpty)
    }

    @Test func aFileNameThatIsNotABareNameIsIgnored() {
        let refs = parse(#"{"files": {"mic": "../secret.caf", "system": "a/b.caf"}}"#)
        #expect(refs.isEmpty)
        #expect(parse(#"{"files": {"mic": ""}}"#).isEmpty)
    }

    @Test func aNegativeOffsetBecomesZero() {
        let refs = parse(#"{"files": {"mic": "mic.caf"}, "start_offset_ms": {"mic": -50}}"#)
        #expect(refs.first?.offsetMs == 0)
    }

    @Test func infoKeepsOnlyTracksWhoseFileExistsAndAsksForTheirLength() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-tracks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"files": {"mic": "mic.caf", "system": "system.caf"}, "start_offset_ms": {"mic": 0, "system": 700}}"#.utf8)
            .write(to: dir.appendingPathComponent("meta.json"))
        try Data([0]).write(to: dir.appendingPathComponent("mic.caf"))   // system.caf is gone

        let infos = SessionTracks.info(in: dir, length: { _ in 12.5 })
        #expect(infos.count == 1)
        #expect(infos[0].id == .mic)
        #expect(infos[0].url == dir.appendingPathComponent("mic.caf"))
        #expect(infos[0].length == 12.5)
    }

    @Test func infoOfAFolderWithoutMetaIsEmpty() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meetingvox-none-\(UUID().uuidString)")
        #expect(SessionTracks.info(in: dir, length: { _ in 1 }).isEmpty)
    }

    @Test func aFileThatCannotBeReadHasLengthZeroNotAFailure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-tracks-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"files": {"mic": "mic.caf"}}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        try Data("not audio".utf8).write(to: dir.appendingPathComponent("mic.caf"))
        let infos = SessionTracks.info(in: dir)   // real AVAudioFile reader
        #expect(infos.count == 1)
        #expect(infos[0].length == 0)
    }
}
