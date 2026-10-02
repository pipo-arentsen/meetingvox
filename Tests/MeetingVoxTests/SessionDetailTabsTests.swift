import Foundation
import Testing
@testable import MeetingVox

/// What the tabs read off the main thread (minutes text, transcript lines)
/// and the Minuta tab's "Generar minuta" (DT-2): the chosen template is
/// written to meta.json first, then the user-requested job is asked for, and
/// nothing is left behind that a relaunch could resume as an automatic job.
@MainActor
@Suite final class SessionDetailTabsTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-detail-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"started": "2026-09-27T10:00:00Z", "duration_seconds": 600, "files": {"mic": "mic.caf"}, "ambito": "trabajo"}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
        try Data(#"{"engine": "fake", "model": "fake", "segments": [{"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "hola"}]}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func metaText() -> String {
        String(decoding: (try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta))) ?? Data(), as: UTF8.self)
    }

    private func model() -> SessionDetailModel {
        SessionDetailModel(inputs: { .none }, load: { dir, _, _ in SessionDetailData(dir: dir) })
    }

    // MARK: - Data the tabs read

    @Test func loadReadsTheMinutesTextAndTheTranscriptLines() throws {
        try Data("# Minuta\n\ntexto".utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes))
        let data = SessionDetailData.load(dir, .none)
        #expect(data.minutesText == "# Minuta\n\ntexto")
        #expect(data.transcriptLines?.map(\.rendered) == ["[00:00] Yo: hola"])
    }

    @Test func loadLeavesBothNilWhenTheFilesAreMissing() throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        let data = SessionDetailData.load(dir, .none)
        #expect(data.minutesText == nil)
        #expect(data.transcriptLines == nil)
    }

    @Test func invalidUTF8InTheMinutesIsReadLossilyNotDropped() throws {
        try Data([0x23, 0x20, 0x41, 0xFF, 0x42]).write(to: dir.appendingPathComponent(SessionFiles.minutes))
        let text = SessionDetailData.load(dir, .none).minutesText
        #expect(text?.hasPrefix("# A") == true)
        #expect(text?.hasSuffix("B") == true)
    }

    // MARK: - Generar minuta

    @Test func generarWritesTheChosenTemplateThenRequestsTheJobAndLeavesNoMarker() async {
        let session = model()
        var metaWhenRequested: String?
        var requested: [URL] = []
        session.commands.generateFromWindow = { [self] dir in
            metaWhenRequested = metaText()
            requested.append(dir)
            return true
        }

        await session.generateMinutes(templateID: "daily", dir: dir).value

        #expect(requested == [dir])
        #expect(metaWhenRequested?.contains(#""minutes_template" : "daily""#) == true, "the choice is on disk before the job reads it")
        #expect(metaWhenRequested?.contains("trabajo") == true, "the other meta.json keys survive")
        #expect(!SessionFiles.exists(SessionFiles.minutesPending, in: dir), "a user-requested job never leaves the automatic marker")
        #expect(session.notice(for: dir) == nil)
    }

    @Test func aChoiceThatCannotBeSavedRequestsNothingAndSaysWhy() async throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.meta))
        let session = model()
        var requested = 0
        session.commands.generateFromWindow = { _ in requested += 1; return true }

        await session.generateMinutes(templateID: "daily", dir: dir).value

        #expect(requested == 0, "otherwise the job would silently use the configured template")
        #expect(session.notice(for: dir) == Textos.Principal.plantillaNoGuardada)
    }

    @Test func generarRechecksTheDiskAndRefusesWhenMinutesAreNowOwedOrThere() async throws {
        for marker in [SessionFiles.minutes, SessionFiles.minutesPending, SessionFiles.minutesError] {
            let session = model()
            var requested = 0
            var reloads = 0
            session.commands.generateFromWindow = { _ in requested += 1; return true }
            session.onListNeedsReload = { reloads += 1 }
            try Data().write(to: dir.appendingPathComponent(marker))

            await session.generateMinutes(templateID: "daily", dir: dir).value

            #expect(requested == 0, "\(marker)")
            #expect(reloads == 1, "\(marker)")
            #expect(session.notice(for: dir) == Textos.Principal.minutaCambio, "\(marker)")
            #expect(!metaText().contains("minutes_template"), "a refused request writes nothing: \(marker)")
            try FileManager.default.removeItem(at: dir.appendingPathComponent(marker))
        }
    }

    @Test func generarWithoutATranscriptIsRefusedToo() async throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        let session = model()
        var requested = 0
        session.commands.generateFromWindow = { _ in requested += 1; return true }

        await session.generateMinutes(templateID: "daily", dir: dir).value

        #expect(requested == 0)
    }

    @Test func aNewGenerarClearsTheEarlierNotice() async throws {
        let session = model()
        session.commands.generateFromWindow = { _ in true }
        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.meta))
        await session.generateMinutes(templateID: "daily", dir: dir).value
        #expect(session.notice(for: dir) != nil)

        try Data(#"{"started": "2026-09-27T10:00:00Z"}"#.utf8).write(to: dir.appendingPathComponent(SessionFiles.meta))
        await session.generateMinutes(templateID: "daily", dir: dir).value
        #expect(session.notice(for: dir) == nil)
    }

    // MARK: - A refused job gives the template back

    private func metaTemplate() -> String? { SessionFiles.chosenMinutesTemplate(in: dir) }

    @Test func aJobTheCoordinatorRefusesRestoresTheEarlierChoice() async throws {
        try SessionFiles.setChosenMinutesTemplate("general", in: dir)
        let session = model()
        session.commands.generateFromWindow = { _ in false }
        var reloads = 0
        session.onListNeedsReload = { reloads += 1 }

        await session.generateMinutes(templateID: "daily", dir: dir).value

        #expect(metaTemplate() == "general", "the refused pick does not stay behind")
        #expect(session.notice(for: dir) == Textos.Principal.minutaCambio)
        #expect(reloads == 1)
    }

    @Test func aRefusedJobForASessionWithNoEarlierChoiceLeavesNone() async {
        let session = model()
        session.commands.generateFromWindow = { _ in false }

        await session.generateMinutes(templateID: "daily", dir: dir).value

        #expect(metaTemplate() == nil)
        #expect(!metaText().contains("minutes_template"), "the key is gone, not blank")
        #expect(metaText().contains("trabajo"), "the other keys survive")
    }

    @Test func anAcceptedJobKeepsTheNewChoice() async throws {
        try SessionFiles.setChosenMinutesTemplate("general", in: dir)
        let session = model()
        session.commands.generateFromWindow = { _ in true }

        await session.generateMinutes(templateID: "daily", dir: dir).value

        #expect(metaTemplate() == "daily")
        #expect(session.notice(for: dir) == nil)
    }
}
