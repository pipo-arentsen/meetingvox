import Foundation
import Testing
@testable import MeetingVox

private let glossary = [
    GlossaryEntry(term: "MeetingVox", variants: ["miting vox"]),
    GlossaryEntry(term: "Kafka", variants: ["kafca"], transcript: false),
]

private func segment(_ text: String, raw: String? = nil) -> TranscriptDocument.Segment {
    TranscriptDocument.Segment(speaker: "me", start_ms: 0, end_ms: 1000, text: text, text_raw: raw)
}

private func modified(_ dir: URL, _ name: String) throws -> Date? {
    try dir.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

private func setModified(_ dir: URL, _ name: String, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir.appendingPathComponent(name).path)
}

@Suite struct TranscriptGlossaryTests {
    @Test func appliesOnlyFlaggedEntriesAndKeepsTheRawText() {
        let result = TranscriptGlossary.apply([segment("con miting vox y kafca"), segment("nada")], glossary: glossary)
        #expect(result.segments.map(\.text) == ["con MeetingVox y kafca", "nada"])
        #expect(result.segments.map(\.text_raw) == ["con miting vox y kafca", "nada"])
        #expect(result.replacements == 1)
    }

    @Test func startsFromTheRawTextSoItNeverCompounds() {
        let once = TranscriptGlossary.apply([segment("miting vox")], glossary: glossary)
        #expect(TranscriptGlossary.apply(once.segments, glossary: glossary) == once)
        // The glossary lost the term: the text goes back to what was said.
        let emptied = TranscriptGlossary.apply(once.segments, glossary: [])
        #expect(emptied.segments.map(\.text) == ["miting vox"])
        #expect(emptied.segments.map(\.text_raw) == ["miting vox"])
        #expect(emptied.replacements == 0)
    }

    @Test func reapplyOnALegacyTranscriptKeepsItsOtherFields() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false, text: "con miting vox")

        #expect(try TranscriptGlossary.reapply(in: dir, glossary: glossary) == .rewritten(replacements: 1))

        let document = try TranscriptDocument.read(from: dir)
        #expect(document.engine == "fake")
        #expect(document.model == "fake")
        #expect(document.created_at == "2026-09-23T15:10:00Z")
        #expect(document.segments.map(\.speaker) == ["me", "them"])
        #expect(document.segments.map(\.text) == ["con MeetingVox", "Buenas"])
        #expect(document.segments.map(\.text_raw) == ["con miting vox", "Buenas"])
        let md = try String(contentsOf: dir.appendingPathComponent(SessionFiles.transcriptMD), encoding: .utf8)
        #expect(md.contains("con MeetingVox"))
        #expect(!md.contains("miting vox"))
    }

    @Test func reapplyIsIdempotentAndLeavesAnUnchangedFileAlone() throws {
        let fixture = try SessionFixture()
        let past = Date(timeIntervalSince1970: 1_700_000_000)

        let dir = try fixture.session("s1", pending: false, text: "con miting vox")
        _ = try TranscriptGlossary.reapply(in: dir, glossary: glossary)
        try setModified(dir, SessionFiles.transcriptJSON, past)
        #expect(try TranscriptGlossary.reapply(in: dir, glossary: glossary) == .unchanged)
        #expect(try modified(dir, SessionFiles.transcriptJSON) == past)

        // A legacy transcript with nothing to replace isn't touched either
        // (and stays legacy: no text_raw).
        let plain = try fixture.session("s2", pending: false, text: "hola")
        try setModified(plain, SessionFiles.transcriptJSON, past)
        #expect(try TranscriptGlossary.reapply(in: plain, glossary: glossary) == .unchanged)
        #expect(try modified(plain, SessionFiles.transcriptJSON) == past)
        #expect(try TranscriptDocument.read(from: plain).segments.allSatisfy { $0.text_raw == nil })
    }

    @Test func reapplyAfterTheGlossaryChangedRestartsFromTheRawText() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", pending: false, text: "con miting vox")
        _ = try TranscriptGlossary.reapply(in: dir, glossary: glossary)
        #expect(try TranscriptGlossary.reapply(in: dir, glossary: []) == .rewritten(replacements: 0))
        #expect(try TranscriptDocument.read(from: dir).segments.first?.text == "con miting vox")
    }

    @Test func missingTranscriptThrows() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("s1", transcript: false, pending: false)
        #expect(throws: (any Error).self) { try TranscriptGlossary.reapply(in: dir, glossary: glossary) }
    }
}
