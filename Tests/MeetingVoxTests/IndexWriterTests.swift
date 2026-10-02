import Foundation
import Testing
@testable import MeetingVox

@Suite struct IndexWriterTests {
    private func tempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeJSON(_ object: [String: Any], to url: URL) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try! data.write(to: url)
    }

    private func writeSession(_ root: URL, name: String, title: String) -> URL {
        let dir = root.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeJSON([
            "started": "2026-09-24T10:30:00Z",
            "duration_seconds": 1800,
            "files": ["mic": "mic.caf"],
        ], to: dir.appendingPathComponent(SessionFiles.meta))
        writeJSON([
            "title": title,
            "summary": "Se revisó el alcance.",
            "client": "Proveedor",
            "topics": ["alcance"],
            "participants": ["Participante 1"],
            "source": "transcript",
            "model": "openai/gpt-4o-mini",
            "generated_at": "2026-09-24T11:00:00Z",
        ], to: dir.appendingPathComponent(SessionFiles.summaryJSON))
        try! SessionFiles.writeMarker(SessionFiles.transcriptJSON, in: dir)
        return dir
    }

    @Test func regenerateWritesIndexMatchingRenderedEntries() throws {
        let root = tempRoot()
        _ = writeSession(root, name: "2026.09.24-1030", title: "Kickoff Proveedor")

        IndexWriter.regenerate(root: root)

        let indexURL = root.appendingPathComponent(SessionFiles.index)
        let written = try String(contentsOf: indexURL, encoding: .utf8)
        let expected = IndexRenderer.render(entries: SessionFiles.sessions(in: root).map(MeetingEntry.load))
        #expect(written == expected)
        #expect(written.contains("Kickoff Proveedor"))
    }

    @Test func regenerateOverwritesTheWholeFileRatherThanAppending() throws {
        let root = tempRoot()
        _ = writeSession(root, name: "2026.09.24-1030", title: "Primera reunión")
        IndexWriter.regenerate(root: root)
        let indexURL = root.appendingPathComponent(SessionFiles.index)
        let first = try String(contentsOf: indexURL, encoding: .utf8)
        #expect(first.contains("Primera reunión"))

        // Remove that session and add a different one: a stale rebuild would
        // leave "Primera reunión" behind if the write weren't a full rewrite.
        try FileManager.default.removeItem(at: root.appendingPathComponent("2026.09.24-1030"))
        _ = writeSession(root, name: "2026.09.25-0900", title: "Segunda reunión")

        IndexWriter.regenerate(root: root)
        let second = try String(contentsOf: indexURL, encoding: .utf8)
        #expect(second.contains("Segunda reunión"))
        #expect(!second.contains("Primera reunión"))
    }

    @Test func regenerateOnAnEmptyRootWritesAHeaderOnlyIndex() throws {
        let root = tempRoot()

        IndexWriter.regenerate(root: root)

        let indexURL = root.appendingPathComponent(SessionFiles.index)
        let written = try String(contentsOf: indexURL, encoding: .utf8)
        #expect(written.contains("# Índice de reuniones"))
    }
}
