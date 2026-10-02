import Foundation
import Testing
@testable import MeetingVox

/// A rescan reads the selected session again, but `transcript.json` and
/// `minuta.md` are the two big files: they are parsed again only when their
/// modification time or size changed (or the folder is another one).
@MainActor
@Suite final class SessionDetailReuseTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-detail-reuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(SessionFiles.meta, #"{"started": "2026-09-27T10:00:00Z", "files": {"mic": "mic.caf"}}"#)
        try write(SessionFiles.transcriptJSON, #"{"segments": [{"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "hola"}]}"#)
        try write(SessionFiles.minutes, "# Minuta")
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private let sentinelLines = [TranscriptViewLine(id: 0, startMs: 0, speaker: "them", text: "SENTINEL")]

    /// A previous read whose big fields were replaced by markers a fresh read
    /// could never produce, so "reused" is observable.
    private func markedPrevious() -> SessionDetailData {
        var previous = SessionDetailData.load(dir, .none)
        previous.transcriptLines = sentinelLines
        previous.minutesText = "SENTINEL"
        return previous
    }

    @Test func aFirstReadRecordsTheStampsOfTheTwoFiles() {
        let data = SessionDetailData.load(dir, .none)
        #expect(data.transcriptStamp != nil)
        #expect(data.minutesStamp != nil)
        #expect((data.transcriptStamp?.size ?? 0) > 0)
    }

    @Test func unchangedFilesAreNotReadAgain() {
        let data = SessionDetailData.load(dir, .none, reusing: markedPrevious())
        #expect(data.transcriptLines == sentinelLines, "transcript.json not parsed again")
        #expect(data.minutesText == "SENTINEL", "minuta.md not read again")
    }

    @Test func aTranscriptWhoseSizeChangedIsParsedAgain() throws {
        let previous = markedPrevious()
        try write(SessionFiles.transcriptJSON, #"{"segments": [{"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "hola de nuevo"}]}"#)
        let data = SessionDetailData.load(dir, .none, reusing: previous)
        #expect(data.transcriptLines?.map(\.text) == ["hola de nuevo"])
        #expect(data.minutesText == "SENTINEL", "the minutes did not change")
    }

    @Test func aSameSizeRewriteWithANewModificationTimeIsReadAgain() throws {
        let previous = markedPrevious()
        try write(SessionFiles.minutes, "# Minuti")   // same size as "# Minuta"
        let url = dir.appendingPathComponent(SessionFiles.minutes)
        let later = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        let data = SessionDetailData.load(dir, .none, reusing: previous)
        #expect(data.minutesText == "# Minuti")
        #expect(data.transcriptLines == sentinelLines)
    }

    @Test func minutesThatAppearedAfterTheLastReadAreReadAndMinutesThatWentAwayAreDropped() throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.minutes))
        let without = SessionDetailData.load(dir, .none)
        #expect(without.minutesText == nil)
        #expect(without.minutesStamp == nil)

        try write(SessionFiles.minutes, "# Nueva")
        let appeared = SessionDetailData.load(dir, .none, reusing: without)
        #expect(appeared.minutesText == "# Nueva")

        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.minutes))
        let gone = SessionDetailData.load(dir, .none, reusing: appeared)
        #expect(gone.minutesText == nil)
    }

    @Test func aPreviousReadOfAnotherFolderIsIgnored() throws {
        var other = markedPrevious()
        other = SessionDetailData(
            dir: dir.deletingLastPathComponent().appendingPathComponent("otra", isDirectory: true),
            transcriptLines: other.transcriptLines, transcriptStamp: other.transcriptStamp,
            minutesText: other.minutesText, minutesStamp: other.minutesStamp
        )
        let data = SessionDetailData.load(dir, .none, reusing: other)
        #expect(data.transcriptLines?.map(\.text) == ["hola"])
        #expect(data.minutesText == "# Minuta")
    }

    @Test func aTranscriptThatCouldNotBeParsedIsTriedAgainNextTime() throws {
        try write(SessionFiles.transcriptJSON, "{ not json")
        let broken = SessionDetailData.load(dir, .none)
        #expect(broken.transcriptLines == nil)
        try write(SessionFiles.transcriptJSON, #"{"segments": [{"speaker": "me", "start_ms": 0, "text": "ok"}]}"#)
        let fixed = SessionDetailData.load(dir, .none, reusing: broken)
        #expect(fixed.transcriptLines?.map(\.text) == ["ok"])
    }

    // MARK: - The model hands the current data of the same folder to the load

    private actor Seen {
        var previous: [URL?] = []
        func add(_ data: SessionDetailData?) { previous.append(data?.dir) }
    }

    @Test func reloadingHandsTheCurrentDataToTheLoadButSelectingAnotherFolderDoesNot() async {
        let seen = Seen()
        let model = SessionDetailModel(inputs: { .none }, load: { dir, _, previous in
            await seen.add(previous)
            return SessionDetailData(dir: dir)
        })
        let other = dir.deletingLastPathComponent().appendingPathComponent("otra", isDirectory: true)
        await model.select(dir).value
        await model.reload().value
        await model.select(other).value

        let calls = await seen.previous
        #expect(calls == [nil, dir, nil])
    }
}
