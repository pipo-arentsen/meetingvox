import Foundation
import Testing
@testable import MeetingVox

private let mexico = TimeZone(identifier: "America/Mexico_City")!
private let options = HindsightFacts.Options(ownerName: "Usuario", glossary: [], timeZone: mexico)

private func writeJSON(_ object: [String: Any], _ dir: URL, _ name: String) throws {
    try JSONSerialization.data(withJSONObject: object).write(to: dir.appendingPathComponent(name))
}

private func setModified(_ dir: URL, _ name: String, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir.appendingPathComponent(name).path)
}

@Suite struct HindsightFactsTests {
    @Test func readsTranscriptWordsDurationAndMarkers() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false, text: "hola a todos")
        try SessionFiles.writeMarker(SessionFiles.hindsightSkip, in: dir)
        let input = try HindsightSessionInput.read(from: dir)
        let hash = HindsightPayloadBuilder.contentHash(try HindsightPayloadBuilder.content(
            HindsightPayloadBuilder.turns(input.segments, started: input.started, ownerName: "Usuario", glossary: [], timeZone: mexico)
        ))
        try HindsightFacts.writeJSON(HindsightErrorRecord(status: 422, message: "field required", hash: hash), dir, SessionFiles.hindsightError)

        let facts = HindsightFacts.read(dir, options)
        #expect(facts.hasTranscript)
        #expect(facts.words == 4)
        #expect(facts.durationSeconds == 3900)
        #expect(facts.skipped)
        #expect(facts.failed)
        #expect(facts.request == nil)
        #expect(facts.sent == nil)
        #expect(facts.contentHash == hash)
        #expect(!facts.isSubscribed)
    }

    /// A `hindsight.error` left over from a rejection of the *previous*
    /// content must not read as an error once the session is re-transcribed
    /// — that's a pending resend, not a failure, even though the
    /// file is still on disk (removed only by "Reintentar envío" or a
    /// later successful send).
    @Test func failedRequiresTheErrorHashToMatchTheCurrentContent() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try HindsightFacts.writeJSON(
            HindsightErrorRecord(status: 422, message: "field required", hash: "stale-hash-from-before"), dir, SessionFiles.hindsightError
        )

        let facts = HindsightFacts.read(dir, options)
        #expect(!facts.failed, "the error was recorded for different content")
        #expect(facts.contentHash != "stale-hash-from-before")
    }

    @Test func durationFallsBackToTheLastSegment() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try writeJSON(["started": "2026-09-23T14:05:00Z"], dir, SessionFiles.meta)
        let facts = HindsightFacts.read(dir, options)
        #expect(facts.durationSeconds == 2)
        #expect(HindsightFacts.duration(metaSeconds: nil, segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 200_000, text: "a"),
            .init(speaker: "them", start_ms: 150_000, end_ms: nil, text: "b"),
        ]) == 200)
        #expect(HindsightFacts.duration(metaSeconds: nil, segments: []) == nil)
    }

    @Test(arguments: [
        (149, 600, true), (150, 600, false), (500, 119, true), (500, 120, false), (500, nil, true),
    ] as [(Int, Int?, Bool)])
    func shortMeansFewerWordsOrFewerMinutes(words: Int, seconds: Int?, short: Bool) {
        #expect(HindsightFacts.isShort(words: words, durationSeconds: seconds, minWords: 150, minMinutes: 2) == short)
    }

    @Test func legacyV1RecordIsIgnored() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.24-1053", pending: false)
        try writeJSON([
            "hash": "d6a1", "operation_id": "d6a1268e-e9a8-5dd9-98ca-3cf774107a55", "sent_at": "2026-09-24T18:08:36Z",
            "document_ids": ["quill-2026.09.24-1053-minuta", "quill-2026.09.24-1053-transcripcion"],
        ], dir, SessionFiles.hindsightSent)
        #expect(HindsightFacts.readSent(dir) == nil)
        #expect(!HindsightFacts.read(dir, options).isSubscribed)

        try writeJSON([
            "document_id": "quill-2026.09.24-1053", "content_hash": "x", "operation_id": "o", "sent_at": "2026-09-24T18:08:36Z",
        ], dir, SessionFiles.hindsightSent)
        #expect(HindsightFacts.readSent(dir) == nil, "a non-mv- document id is legacy too")
    }

    @Test func v2RecordIsCurrentUntilTheTranscriptChanges() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let input = try HindsightSessionInput.read(from: dir)
        let hash = HindsightPayloadBuilder.contentHash(try HindsightPayloadBuilder.content(
            HindsightPayloadBuilder.turns(input.segments, started: input.started, ownerName: "Usuario", glossary: [], timeZone: mexico)
        ))
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1405", contentHash: hash, operationID: "o", sentAt: Date(timeIntervalSince1970: 0)),
            dir, SessionFiles.hindsightSent
        )
        #expect(HindsightFacts.read(dir, options).isSentCurrent)
        #expect(HindsightFacts.read(dir, options).isSubscribed)

        let other = HindsightFacts.Options(ownerName: "Otro nombre", glossary: [], timeZone: mexico)
        #expect(!HindsightFacts.read(dir, other).isSentCurrent, "the owner name is part of the content")
    }

    @Test func requestMarkerRoundTripsAndAMalformedOneIsAPlainRequest() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let marker = HindsightRequestMarker(force: true, requestedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try HindsightFacts.writeJSON(marker, dir, SessionFiles.hindsightRequested)
        #expect(HindsightFacts.readRequest(dir) == marker)

        try Data("{".utf8).write(to: dir.appendingPathComponent(SessionFiles.hindsightRequested))
        #expect(HindsightFacts.readRequest(dir) == HindsightRequestMarker(force: false, requestedAt: nil))

        try Data(#"{"force": true}"#.utf8).write(to: dir.appendingPathComponent(SessionFiles.hindsightRequested))
        #expect(HindsightFacts.readRequest(dir) == HindsightRequestMarker(force: true, requestedAt: nil))
    }

    // MARK: - readCheap (sessions menu: no hashing)

    @Test func readCheapMatchesWordsAndDurationOfTheFullRead() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false, text: "hola a todos")

        let cheap = HindsightFacts.readCheap(dir)
        #expect(cheap.hasTranscript)
        #expect(cheap.words == HindsightFacts.read(dir, options).words)
        #expect(cheap.durationSeconds == HindsightFacts.read(dir, options).durationSeconds)
    }

    @Test func readCheapTreatsASentRecordNewerThanTheTranscriptAsCurrent() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let now = Date()
        try setModified(dir, SessionFiles.transcriptJSON, now)
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1405", contentHash: "h1", operationID: "o", sentAt: now),
            dir, SessionFiles.hindsightSent
        )
        try setModified(dir, SessionFiles.hindsightSent, now.addingTimeInterval(1))

        #expect(HindsightFacts.readCheap(dir).isSentCurrent)
    }

    @Test func readCheapTreatsASentRecordOlderThanARetranscriptionAsStale() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let now = Date()
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-2026.09.23-1405", contentHash: "h1", operationID: "o", sentAt: now),
            dir, SessionFiles.hindsightSent
        )
        try setModified(dir, SessionFiles.hindsightSent, now)
        try setModified(dir, SessionFiles.transcriptJSON, now.addingTimeInterval(60))

        #expect(!HindsightFacts.readCheap(dir).isSentCurrent, "re-transcribed after the send: stale")
    }

    @Test func readCheapTreatsAnErrorNewerThanTheTranscriptAsFailed() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let now = Date()
        try setModified(dir, SessionFiles.transcriptJSON, now)
        try HindsightFacts.writeJSON(HindsightErrorRecord(status: 422, message: "x", hash: "h1"), dir, SessionFiles.hindsightError)
        try setModified(dir, SessionFiles.hindsightError, now.addingTimeInterval(1))

        #expect(HindsightFacts.readCheap(dir).failed)
    }

    @Test func readCheapTreatsAnErrorOlderThanARetranscriptionAsNotFailed() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        let now = Date()
        try HindsightFacts.writeJSON(HindsightErrorRecord(status: 422, message: "x", hash: "h1"), dir, SessionFiles.hindsightError)
        try setModified(dir, SessionFiles.hindsightError, now)
        try setModified(dir, SessionFiles.transcriptJSON, now.addingTimeInterval(60))

        #expect(!HindsightFacts.readCheap(dir).failed, "re-transcribed after the rejection: not an error anymore")
    }

    @Test func noTranscriptMeansNoTranscriptFacts() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", transcript: false, pending: false)
        let facts = HindsightFacts.read(dir, options)
        #expect(!facts.hasTranscript)
        #expect(facts.words == 0)
    }

    /// Review focus 2: the hash the window/coordinator compare against
    /// must be the payload's, for corrected and legacy transcripts alike —
    /// and both give the same content, so "Aplicar glosario" on a session
    /// already in memory doesn't resend it.
    @Test func contentHashMatchesThePayloadForCorrectedAndLegacyTranscripts() throws {
        let glossary = [
            GlossaryEntry(term: "MeetingVox", variants: ["miting vox"]),
            GlossaryEntry(term: "Kafka", variants: ["kafca"], transcript: false),
        ]
        let fixture = try SessionFixture()
        var hashes: [String] = []
        for (name, corrected) in [("2026.09.23-1405", true), ("2026.09.23-1406", false)] {
            let dir = try fixture.session(name, pending: false, text: "miting vox y kafca")
            if corrected { _ = try TranscriptGlossary.reapply(in: dir, glossary: glossary) }
            try HindsightFacts.writeJSON(
                HindsightSentRecord(documentID: "mv-\(name)", contentHash: "old", operationID: "op", sentAt: Date()),
                dir, SessionFiles.hindsightSent
            )
            let payload = try #require(try HindsightPayloadBuilder.build(
                HindsightSessionInput.read(from: dir),
                HindsightBuildOptions(
                    ownerName: "Usuario", ownerDescription: "", glossary: glossary, timeZone: mexico,
                    configTemplate: "general", templateName: { _ in nil }
                )
            ))
            let facts = HindsightFacts.read(dir, HindsightFacts.Options(ownerName: "Usuario", glossary: glossary, timeZone: mexico))
            #expect(facts.contentHash == payload.contentHash)
            hashes.append(payload.contentHash)
        }
        #expect(hashes[0] == hashes[1])
    }

    // MARK: Banks

    @Test func targetBankPrefersTheRecordedBank() {
        let sent = HindsightSentRecord(documentID: "mv-x", contentHash: "h", operationID: "o", sentAt: Date(), bank: "a")
        let legacy = HindsightSentRecord(documentID: "mv-x", contentHash: "h", operationID: "o", sentAt: Date())
        let request = HindsightRequestMarker(force: false, requestedAt: nil, bank: "b")
        let error = HindsightErrorRecord(status: 422, message: nil, hash: "h", bank: "c")
        #expect(HindsightFacts.targetBank(sent: sent, request: request, error: error, defaultBank: "d") == "a")
        #expect(HindsightFacts.targetBank(sent: legacy, request: request, error: error, defaultBank: "d") == "d")
        #expect(HindsightFacts.targetBank(sent: nil, request: request, error: error, defaultBank: "d") == "b")
        #expect(HindsightFacts.targetBank(sent: nil, request: nil, error: error, defaultBank: "d") == "c")
        #expect(HindsightFacts.targetBank(sent: nil, request: nil, error: nil, defaultBank: "d") == "d")
        #expect(HindsightFacts.targetBank(sent: nil, request: nil, error: nil, defaultBank: nil) == nil)
    }

    @Test func recordsWithoutABankStillDecode() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try writeJSON(["document_id": "mv-2026.09.23-1405", "content_hash": "h", "operation_id": "o",
                       "sent_at": "2026-09-23T15:00:00Z"], dir, SessionFiles.hindsightSent)
        try writeJSON(["force": true, "requested_at": "2026-09-23T15:00:00Z"], dir, SessionFiles.hindsightRequested)
        try writeJSON(["status": 422, "hash": "h"], dir, SessionFiles.hindsightError)
        #expect(HindsightFacts.readSent(dir)?.bank == nil)
        #expect(HindsightFacts.readRequest(dir) == HindsightRequestMarker(
            force: true, requestedAt: ISO8601DateFormatter().date(from: "2026-09-23T15:00:00Z")
        ))
        #expect(HindsightFacts.readError(dir)?.bank == nil)

        try HindsightFacts.writeJSON(HindsightRequestMarker(force: false, requestedAt: nil, bank: "archivo"), dir, SessionFiles.hindsightRequested)
        #expect(HindsightFacts.readRequest(dir)?.bank == "archivo")
    }

    /// A blank/whitespace-only `bank` on disk (or passed
    /// directly to `targetBank`) means "none recorded", same as absent.
    @Test func blankBankNormalizesToNilOnDecodeAndInTargetBank() throws {
        let fixture = try SessionFixture()
        let dir = try fixture.session("2026.09.23-1405", pending: false)
        try writeJSON(["document_id": "mv-2026.09.23-1405", "content_hash": "h", "operation_id": "o",
                       "sent_at": "2026-09-23T15:00:00Z", "bank": "   "], dir, SessionFiles.hindsightSent)
        try writeJSON(["status": 422, "hash": "h", "bank": ""], dir, SessionFiles.hindsightError)
        try writeJSON(["force": false, "bank": " \n"], dir, SessionFiles.hindsightRequested)
        #expect(HindsightFacts.readSent(dir)?.bank == nil)
        #expect(HindsightFacts.readError(dir)?.bank == nil)
        #expect(HindsightFacts.readRequest(dir)?.bank == nil)

        let sent = HindsightSentRecord(documentID: "mv-x", contentHash: "h", operationID: "o", sentAt: Date(), bank: " ")
        let request = HindsightRequestMarker(force: false, requestedAt: nil, bank: "")
        let error = HindsightErrorRecord(status: 422, message: nil, hash: "h", bank: "  ")
        #expect(HindsightFacts.targetBank(sent: sent, request: nil, error: nil, defaultBank: "d") == "d")
        #expect(HindsightFacts.targetBank(sent: nil, request: request, error: nil, defaultBank: "d") == "d")
        #expect(HindsightFacts.targetBank(sent: nil, request: nil, error: error, defaultBank: "d") == "d")
        #expect(HindsightFacts.targetBank(sent: nil, request: nil, error: nil, defaultBank: "  ") == nil)
    }
}
