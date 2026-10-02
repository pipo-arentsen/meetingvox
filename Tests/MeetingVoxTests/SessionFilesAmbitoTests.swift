import Foundation
import Testing
@testable import MeetingVox

@Suite final class SessionFilesAmbitoTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-ambito-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private var metaURL: URL { dir.appendingPathComponent(SessionFiles.meta) }

    private func writeMeta(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: metaURL)
    }

    private func readMeta() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
    }

    @Test func setAmbitoKeepsEveryOtherKey() throws {
        try writeMeta([
            "started": "2026-09-24T10:53:00Z", "duration_seconds": 720, "minutes_template": "familiar",
            "files": ["mic": "mic.caf"], "future_key": ["nested": 1],
        ])

        try SessionFiles.setAmbito(.trabajo, in: dir)

        let meta = try readMeta()
        #expect(meta["ambito"] as? String == "trabajo")
        #expect(meta["started"] as? String == "2026-09-24T10:53:00Z")
        #expect(meta["duration_seconds"] as? Int == 720)
        #expect(meta["minutes_template"] as? String == "familiar")
        #expect((meta["files"] as? [String: String]) == ["mic": "mic.caf"])
        #expect((meta["future_key"] as? [String: Int]) == ["nested": 1])
        #expect(MeetingEntry.load(dir).ambito == .trabajo)
    }

    @Test func nilRemovesTheKeyAndMeansUnclassified() throws {
        try writeMeta(["started": "2026-09-24T10:53:00Z", "ambito": "personal"])

        try SessionFiles.setAmbito(nil, in: dir)

        let meta = try readMeta()
        #expect(meta["ambito"] == nil)
        #expect(meta["started"] as? String == "2026-09-24T10:53:00Z")
        #expect(MeetingEntry.load(dir).ambito == nil)
    }

    @Test func missingOrCorruptMetaThrowsAndWritesNothing() throws {
        #expect(throws: (any Error).self) { try SessionFiles.setAmbito(.personal, in: dir) }
        #expect(!FileManager.default.fileExists(atPath: metaURL.path))

        let corrupt = Data("{\"started\": ".utf8)
        try corrupt.write(to: metaURL)
        #expect(throws: (any Error).self) { try SessionFiles.setAmbito(.personal, in: dir) }
        #expect(try Data(contentsOf: metaURL) == corrupt)

        try Data("[1, 2]".utf8).write(to: metaURL)
        #expect(throws: (any Error).self) { try SessionFiles.setAmbito(.personal, in: dir) }
        #expect(try Data(contentsOf: metaURL) == Data("[1, 2]".utf8))
    }

    /// Review Focus 1: the Reuniones window (main actor) and
    /// `MinutesCoordinator.regenerate` (its own actor) may update the same
    /// meta.json at once; neither key may be lost.
    @Test func concurrentWritersKeepEveryKey() throws {
        try writeMeta(["started": "2026-09-24T10:53:00Z"])
        let dir = self.dir
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            if i.isMultiple(of: 2) {
                try? SessionFiles.setAmbito(.profesional, in: dir)
            } else {
                try? SessionFiles.setChosenMinutesTemplate("t\(i)", in: dir)
            }
        }
        let meta = try readMeta()
        #expect(meta["ambito"] as? String == "profesional")
        #expect((meta["minutes_template"] as? String)?.hasPrefix("t") == true)
        #expect(meta["started"] as? String == "2026-09-24T10:53:00Z")
    }

    /// Review Focus 5: classifying never changes what Hindsight receives
    /// (so nothing is re-sent) nor the text of indice.md.
    @Test func ambitoNeverChangesTheHindsightPayloadOrTheIndex() throws {
        let fixture = try SessionFixture()
        let session = try fixture.session("2026.09.23-1405", pending: false)
        let options = HindsightBuildOptions(
            ownerName: "Usuario", ownerDescription: "quien grabó la reunión", glossary: [],
            timeZone: TimeZone(identifier: "UTC")!, configTemplate: "general", templateName: { _ in nil }
        )
        let now = ISO8601DateFormatter().date(from: "2026-09-27T12:00:00Z")!
        let utc = TimeZone(identifier: "UTC")!
        let before = try #require(try HindsightPayloadBuilder.build(try HindsightSessionInput.read(from: session), options))
        let indexBefore = IndexRenderer.render(entries: [MeetingEntry.load(session)], now: now, timeZone: utc)

        try SessionFiles.setAmbito(.personal, in: session)

        let after = try #require(try HindsightPayloadBuilder.build(try HindsightSessionInput.read(from: session), options))
        #expect(after.body == before.body)
        #expect(after.contentHash == before.contentHash)
        #expect(IndexRenderer.render(entries: [MeetingEntry.load(session)], now: now, timeZone: utc) == indexBefore)
    }
}
