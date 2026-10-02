import Foundation
import Testing
@testable import MeetingVox

/// The in-memory full-text index: per-session documents
/// cached by file stamp, rebuilt only for a changed file, dropped on removal
/// and on `clear()`. Real temp folders, never the user's recordings.
@Suite struct FullTextIndexTests {
    private func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-fulltext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func session(_ root: URL, _ name: String, lines: [String], minutes: String? = nil) throws -> MeetingEntry {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"started": "2026-09-29T10:00:00Z"}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        // Speakers alternate so each text stays its own line in the tab.
        let segments = lines.enumerated().map {
            #"{"speaker": "\#($0.offset % 2 == 0 ? "me" : "them")", "start_ms": \#($0.offset * 10_000), "end_ms": \#($0.offset * 10_000 + 1000), "text": "\#($0.element)"}"#
        }.joined(separator: ",")
        try Data(#"{"segments": [\#(segments)]}"#.utf8).write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        if let minutes { try Data(minutes.utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes)) }
        return MeetingEntry.load(dir)
    }

    @Test func aTranscriptOnlyPhraseIsFoundWithItsLine() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try session(root, "2026.09.29-1000", lines: ["hola", "la cotización final"])
        let other = try session(root, "2026.09.29-1100", lines: ["otra cosa"])
        let index = FullTextIndex()
        await index.refresh([entry, other])

        let result = await index.search(query: "cotizacion FINAL", entries: [entry, other])
        #expect(result.matches == [entry.dir])
        #expect(result.hits[entry.dir]?.lineID == 1)
        #expect(result.hits[entry.dir]?.source == .transcript)
    }

    @Test func anEmptyQueryMatchesNothingAndHasNoHits() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try session(root, "a", lines: ["hola"])
        let index = FullTextIndex()
        await index.refresh([entry])
        let result = await index.search(query: "  ", entries: [entry])
        #expect(result.matches.isEmpty && result.hits.isEmpty)
    }

    @Test func minutesTextIsSearchableAndOpensTheMinutes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try session(root, "a", lines: ["hola"], minutes: "<!-- quill minutes template: general -->\n# Acta\n- Se aprobó el presupuesto")
        let index = FullTextIndex()
        await index.refresh([entry])
        let result = await index.search(query: "presupuesto", entries: [entry])
        #expect(result.hits[entry.dir]?.source == .minutes)
        let provenance = await index.search(query: "quill", entries: [entry])
        #expect(provenance.matches.isEmpty, "the provenance header line is not content")
    }

    @Test func aMetadataMatchIsInTheSetButHasNoSnippet() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var entry = try session(root, "a", lines: ["hola"])
        entry = MeetingEntry(
            dir: entry.dir, started: nil, durationSeconds: nil, app: nil,
            summary: MeetingSummary(
                title: "Kickoff Proveedor", summary: "s", client: nil, topics: [], participants: [],
                source: .transcript, model: "m", generatedAt: Date()
            ),
            hasMinutes: false, hasTranscript: true
        )
        let index = FullTextIndex()
        await index.refresh([entry])
        let result = await index.search(query: "proveedor", entries: [entry])
        #expect(result.matches == [entry.dir])
        #expect(result.hits[entry.dir] == nil)
    }

    @Test func tokensSplitAcrossMetadataAndTranscriptMatchTheSession() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var entry = try session(root, "a", lines: ["hablamos de la cotización"])
        entry = MeetingEntry(
            dir: entry.dir, started: nil, durationSeconds: nil, app: nil,
            summary: MeetingSummary(
                title: "Kickoff Proveedor", summary: "s", client: nil, topics: [], participants: [],
                source: .transcript, model: "m", generatedAt: Date()
            ),
            hasMinutes: false, hasTranscript: true
        )
        let index = FullTextIndex()
        await index.refresh([entry])
        let result = await index.search(query: "proveedor cotizacion", entries: [entry])
        #expect(result.matches == [entry.dir])
        #expect(result.hits[entry.dir]?.lineID == 0)
    }

    // MARK: - Stamp cache

    @Test func unchangedFilesAreNotReadAgain() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try session(root, "a", lines: ["hola"], minutes: "# Acta")
        let index = FullTextIndex()
        await index.refresh([entry])
        #expect(await index.loadCount == 1)
        await index.refresh([entry])
        await index.refresh([MeetingEntry.load(entry.dir)])
        #expect(await index.loadCount == 1, "same stamps: the cached document is reused")
    }

    @Test func aMinutesFileEditedAfterIndexingIsReadAgainAndItsNewTextIsSearchable() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try session(root, "a", lines: ["hola"], minutes: "# Acta\n- viejo")
        let other = try session(root, "b", lines: ["chao"])
        let index = FullTextIndex()
        await index.refresh([entry, other])
        #expect(await index.loadCount == 2)
        #expect((await index.search(query: "nuevisimo", entries: [entry])).matches.isEmpty)

        try Data("# Acta\n- texto nuevisimo agregado después".utf8).write(to: entry.dir.appendingPathComponent(SessionFiles.minutes))
        await index.refresh([entry, other])
        #expect(await index.loadCount == 3, "only the edited session is re-read")
        #expect((await index.search(query: "nuevisimo", entries: [entry])).matches == [entry.dir])
    }

    @Test func aSessionThatLeavesTheListIsForgotten() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try session(root, "a", lines: ["hola"])
        let b = try session(root, "b", lines: ["hola"])
        let index = FullTextIndex()
        await index.refresh([a, b])
        #expect(await index.cachedCount == 2)
        await index.refresh([a])
        #expect(await index.cachedCount == 1)
    }

    @Test func clearDropsEverythingAndTheNextRefreshRebuilds() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try session(root, "a", lines: ["la cotización"])
        let index = FullTextIndex()
        await index.refresh([entry])
        await index.clear()
        #expect(await index.cachedCount == 0)
        #expect((await index.search(query: "cotizacion", entries: [entry])).matches.isEmpty, "nothing is searchable until rebuilt")
        await index.refresh([entry])
        #expect(await index.loadCount == 2)
        #expect((await index.search(query: "cotizacion", entries: [entry])).matches == [entry.dir])
    }

    @Test func aSessionWithoutTranscriptOrMinutesCostsNoRead() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        let entry = MeetingEntry.load(dir)
        let index = FullTextIndex()
        await index.refresh([entry])
        #expect(await index.loadCount == 0)
    }
}
