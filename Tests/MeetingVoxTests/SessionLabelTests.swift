import AppKit
import Foundation
import Testing
@testable import MeetingVox

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
private let utc = TimeZone(identifier: "UTC")!

@Suite struct SessionLabelTests {
    private func text(
        title: String? = nil, started: Date? = date("2026-09-24T10:53:00Z"), ended: Date? = nil,
        duration: Int? = 720, folder: String = "2026.09.24-1053", maxLength: Int = SessionLabel.maxLength
    ) -> String {
        SessionLabel.text(
            summaryTitle: title, started: started, ended: ended, durationSeconds: duration,
            folder: folder, timeZone: utc, maxLength: maxLength
        )
    }

    // MARK: - The summary title wins

    @Test func aSummaryTitleIsTheLabel() {
        #expect(text(title: "Kickoff Proveedor") == "Kickoff Proveedor")
    }

    @Test func theTitleIsTrimmed() {
        #expect(text(title: "  Kickoff \n") == "Kickoff")
    }

    // MARK: - Without a title, the row header

    @Test func noTitleFallsBackToTheRowHeader() {
        #expect(text(title: nil) == "Jue 24 sep · 10:53–11:05 (12 min)")
    }

    @Test func aBlankTitleFallsBackToTheRowHeader() {
        #expect(text(title: "   \n ") == "Jue 24 sep · 10:53–11:05 (12 min)")
    }

    @Test func theHeaderUsesEndedWhenPresent() {
        #expect(text(ended: date("2026-09-24T11:20:00Z"), duration: nil) == "Jue 24 sep · 10:53–11:20 (27 min)")
    }

    @Test func noTitleAndNoStartFallsBackToTheFolderName() {
        #expect(text(title: nil, started: nil, folder: "2026.09.24-1053-2") == "2026.09.24-1053-2")
    }

    // MARK: - Truncation

    @Test func anOverlongTitleIsTruncatedWithAnEllipsis() {
        let long = String(repeating: "a", count: 60)
        let label = text(title: long)
        #expect(label.count == SessionLabel.maxLength)
        #expect(label == String(repeating: "a", count: SessionLabel.maxLength - 1) + "…")
    }

    @Test func aTitleOfExactlyTheMaximumIsUntouched() {
        let exact = String(repeating: "b", count: SessionLabel.maxLength)
        #expect(text(title: exact) == exact)
    }

    @Test func truncationDropsTrailingSpacesBeforeTheEllipsis() {
        #expect(text(title: "Reunión semanal con el cliente", maxLength: 8) == "Reunión…")
        #expect(text(title: "Reunión semanal", maxLength: 9) == "Reunión…")
    }

    @Test func aFolderFallbackIsTruncatedToo() {
        #expect(text(title: nil, started: nil, folder: "abcdefghij", maxLength: 5) == "abcd…")
    }

    // MARK: - load(dir) and the menu summary

    private func session(meta: [String: Any]?, summary: [String: Any]?, name: String = "2026.09.24-1053") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let meta {
            try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent(SessionFiles.meta))
        }
        if let summary {
            try JSONSerialization.data(withJSONObject: summary).write(to: dir.appendingPathComponent(SessionFiles.summaryJSON))
        }
        return dir
    }

    private let summaryJSON: [String: Any] = [
        "title": "Kickoff", "summary": "s", "client": NSNull(), "topics": [String](), "participants": [String](),
        "source": "transcript", "model": "m", "generated_at": "2026-09-24T11:00:00Z",
    ]

    @Test func loadReadsTheSummaryTitleFromDisk() throws {
        let dir = try session(meta: ["started": "2026-09-24T10:53:00Z"], summary: summaryJSON)
        #expect(SessionLabel.load(dir, timeZone: utc) == "Kickoff")
    }

    @Test func loadUsesMetaTimesWhenThereIsNoSummary() throws {
        let dir = try session(
            meta: ["started": "2026-09-24T10:53:00Z", "duration_seconds": 720], summary: nil
        )
        #expect(SessionLabel.load(dir, timeZone: utc) == "Jue 24 sep · 10:53–11:05 (12 min)")
    }

    @Test func loadFallsBackToTheFolderDateWithoutMeta() throws {
        let dir = try session(meta: nil, summary: nil, name: "2026.09.24-1053")
        // The folder name is local wall-clock time, so read it back in the local zone.
        #expect(SessionLabel.load(dir, timeZone: .current) == "Jue 24 sep · 10:53")
    }

    @Test func loadFallsBackToTheFolderNameWhenNothingParses() throws {
        let dir = try session(meta: nil, summary: nil, name: "sesion-rara")
        #expect(SessionLabel.load(dir, timeZone: utc) == "sesion-rara")
    }

    // MARK: - The status menu's "Última" uses it

    @Test func theLastSessionItemIsTitledWithItsLabel() throws {
        let dir = try session(meta: ["started": "2026-09-24T10:53:00Z"], summary: summaryJSON)
        let root = dir.deletingLastPathComponent()
        let last = try #require(MenuModel.last(in: root))
        #expect(last.title == "Kickoff")
        #expect(Textos.Menu.ultima(last.title) == "Última: Kickoff")
    }
}
