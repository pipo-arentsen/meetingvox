@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MeetingVox

/// Approval tests for what the rename to MeetingVox must NOT change. These
/// formats are read by the old `quill` binary and by external `on_stop`
/// tools while both apps coexist, and by the Hindsight server across
/// re-sends. They pass on the current code by design; they exist so a future
/// "finish the rename" edit fails loudly instead of silently breaking a
/// consumer.
@Suite("RenameInvariants")
struct RenameInvariantTests {
    // MARK: - Minutes provenance header

    @Test func theMinutesHeaderStillSaysQuillMinutesAndIsParsedBack() throws {
        let header = MinutesCoordinator.provenance(
            model: "m/x", templateID: "comercial",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000), chunked: true
        )

        #expect(header.hasPrefix("<!-- quill minutes"))
        #expect(header.contains("template: comercial"))
        #expect(header.contains("chunked: yes"))
        #expect(MeetingEntry.templateID(fromMinutesHeader: header + "\n\nbody") == "comercial")
    }

    @Test func aHeaderWrittenByTheOldBinaryIsStillParsed() {
        let old = "<!-- quill minutes · model: m/x · template: general · generated_at: 2026-09-24T17:10:29Z · chunked: no -->"

        #expect(MeetingEntry.templateID(fromMinutesHeader: old) == "general")
        // A MeetingVox-prefixed header would NOT be recognized by the old binary; must not be produced.
        #expect(MeetingEntry.templateID(fromMinutesHeader: old.replacingOccurrences(of: "quill minutes", with: "MeetingVox minutes")) == nil)
    }

    // MARK: - transcript.json

    @Test func transcriptJSONKeepsItsKeysAndSpeakerIDs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-invariant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = TranscriptDocument(
            engine: "parakeet", model: "m", created_at: "2026-09-29T10:00:00Z",
            segments: [
                .init(speaker: "me", start_ms: 0, end_ms: 900, text: "hola", text_raw: "ola"),
                .init(speaker: "them", start_ms: 1000, end_ms: nil, text: "buenas", text_raw: nil),
            ]
        )

        try doc.write(to: dir)

        let data = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["engine", "model", "created_at", "segments"])
        let segments = try #require(json["segments"] as? [[String: Any]])
        #expect(segments.count == 2)
        #expect(Set(segments[0].keys) == ["speaker", "start_ms", "end_ms", "text", "text_raw"])
        #expect(segments.map { $0["speaker"] as? String } == ["me", "them"])
    }

    // MARK: - meta.json and the track files

    @Test func metaJSONKeepsItsKeysAndTheTrackFileNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-invariant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(
            root: root, mic: StubTrack(), system: StubTrack(), notify: { _, _ in }
        )

        try session.start()
        session.stop()

        let data = try Data(contentsOf: session.dir.appendingPathComponent("meta.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["started", "ended", "duration_seconds", "files", "start_offset_ms"])
        #expect(json["files"] as? [String: String] == ["mic": "mic.caf", "system": "system.caf"])
        #expect(Set((json["start_offset_ms"] as? [String: Int] ?? [:]).keys) == ["mic", "system"])
        #expect(FileManager.default.fileExists(atPath: session.dir.appendingPathComponent("mic.caf").path))
        #expect(FileManager.default.fileExists(atPath: session.dir.appendingPathComponent("system.caf").path))
    }

    // MARK: - Hindsight ids

    @Test func hindsightDocumentIDsStayMv() {
        #expect(HindsightPayloadBuilder.documentID(session: "2026.09.24-1053") == "mv-2026.09.24-1053")
        #expect(HindsightPayloadBuilder.isCurrentDocumentID("mv-2026.09.24-1053"))
        // Legacy v1 ids are not current (they are replaced on the next send, not re-sent as new).
        #expect(!HindsightPayloadBuilder.isCurrentDocumentID("quill-2026.09.24-1053"))
        #expect(!HindsightPayloadBuilder.isCurrentDocumentID("meetingvox-2026.09.24-1053"))
    }
}

/// A track that just creates its (empty) file.
private final class StubTrack: MicRecording, @unchecked Sendable {
    var diagBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onUnavailable: (@Sendable (Error) -> Void)?
    private(set) var isRecording = false
    private(set) var firstBufferAt: Date?

    func start(writingTo url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        isRecording = true
        firstBufferAt = Date()
    }

    func stop() { isRecording = false }
}
