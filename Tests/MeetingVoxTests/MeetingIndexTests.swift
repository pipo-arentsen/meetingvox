import Foundation
import Testing
@testable import MeetingVox

@Suite struct MeetingIndexTests {
    private func tempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSession(in root: URL, name: String, started: String) {
        let dir = root.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = ["started": started]
        let data = try! JSONSerialization.data(withJSONObject: meta)
        try! data.write(to: dir.appendingPathComponent(SessionFiles.meta))
    }

    @Test func scanReturnsEveryFixtureSession() async throws {
        let root = tempRoot()
        makeSession(in: root, name: "2026.09.24-1030", started: "2026-09-24T10:30:00Z")
        makeSession(in: root, name: "2026.09.23-0900", started: "2026-09-23T09:00:00Z")

        let index = MeetingIndex()
        let entries = await index.scan(root: root)

        #expect(entries.count == 2)
        #expect(Set(entries.map(\.dir.lastPathComponent)) == ["2026.09.24-1030", "2026.09.23-0900"])
    }

    @Test func scanIgnoresNonSessionEntries() async throws {
        let root = tempRoot()
        makeSession(in: root, name: "2026.09.24-1030", started: "2026-09-24T10:30:00Z")
        // No meta.json here — not a session folder.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-session"), withIntermediateDirectories: true
        )

        let index = MeetingIndex()
        let entries = await index.scan(root: root)

        #expect(entries.count == 1)
    }

    @Test func factsAreReadOnlyForTheGivenSessions() async throws {
        let fixture = try SessionFixture()
        let first = try fixture.session("2026.09.23-1405", pending: false)
        try fixture.session("2026.09.22-1405", pending: false)
        let index = MeetingIndex()
        #expect(await index.scan(root: fixture.root).count == 2)
        let options = HindsightFacts.Options(ownerName: "Yo", glossary: [], timeZone: .current)
        let facts = await index.facts(for: [first], options: options)
        #expect(Array(facts.keys) == [first])
        #expect(facts[first]?.hasTranscript == true)
        #expect(facts[first]?.words == 2)
    }
}
