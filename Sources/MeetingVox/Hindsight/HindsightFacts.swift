import Foundation

/// Trims and blank-normalizes a decoded bank string: `""`/whitespace-only
/// means "no bank recorded", the same as absent.
/// Shared by every bank-carrying record's tolerant decoder and by
/// `HindsightFacts.targetBank`.
private func normalizedBank(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

/// `hindsight.json` (v2): the last content Hindsight accepted for a session.
struct HindsightSentRecord: Codable, Equatable, Sendable {
    let documentID: String
    let contentHash: String
    let operationID: String
    let sentAt: Date
    /// The bank it went to (v3). Missing in records written before v3:
    /// those went to the config's default bank.
    var bank: String? = nil

    init(documentID: String, contentHash: String, operationID: String, sentAt: Date, bank: String? = nil) {
        self.documentID = documentID
        self.contentHash = contentHash
        self.operationID = operationID
        self.sentAt = sentAt
        self.bank = bank
    }

    private enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case contentHash = "content_hash"
        case operationID = "operation_id"
        case sentAt = "sent_at"
        case bank
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try c.decode(String.self, forKey: .documentID)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        operationID = try c.decode(String.self, forKey: .operationID)
        sentAt = try c.decode(Date.self, forKey: .sentAt)
        bank = normalizedBank((try? c.decodeIfPresent(String.self, forKey: .bank)) ?? nil)
    }
}

/// `hindsight.error`: a definitive rejection of one content (by content
/// hash), and the bank that rejected it — the rejection removes the
/// request marker, so "Reintentar envío" learns the bank from here.
struct HindsightErrorRecord: Codable, Equatable, Sendable {
    let status: Int
    let message: String?
    let hash: String
    var bank: String? = nil

    init(status: Int, message: String?, hash: String, bank: String? = nil) {
        self.status = status
        self.message = message
        self.hash = hash
        self.bank = bank
    }

    private enum CodingKeys: String, CodingKey {
        case status, message, hash, bank
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(Int.self, forKey: .status)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        hash = try c.decode(String.self, forKey: .hash)
        bank = normalizedBank((try? c.decodeIfPresent(String.self, forKey: .bank)) ?? nil)
    }
}

/// `hindsight.solicitado`: the user asked to send (or, with `force`, to
/// resend) this session, to `bank`.
struct HindsightRequestMarker: Codable, Equatable, Sendable {
    let force: Bool
    /// When it was asked. A forced resend derives its operation id from it,
    /// so a transient failure retried by a later sweep reuses the same id.
    let requestedAt: Date?
    /// The bank chosen when asking (v3; the default is written explicitly).
    /// Nil in older markers → the default bank.
    let bank: String?

    init(force: Bool, requestedAt: Date?, bank: String? = nil) {
        self.force = force
        self.requestedAt = requestedAt
        self.bank = bank
    }

    private enum CodingKeys: String, CodingKey {
        case force
        case requestedAt = "requested_at"
        case bank
    }

    /// Tolerant: missing or odd fields degrade to a plain request.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        force = (try? c.decodeIfPresent(Bool.self, forKey: .force)) ?? false
        requestedAt = try? c.decodeIfPresent(Date.self, forKey: .requestedAt)
        bank = normalizedBank((try? c.decodeIfPresent(String.self, forKey: .bank)) ?? nil)
    }
}

/// Everything the exporter and the main window decide on for one
/// session, read from its folder in one pass — so the window's status and
/// the coordinator's next move always agree.
struct HindsightFacts: Sendable, Equatable {
    /// What the content hash depends on besides the transcript (the glossary
    /// only for transcripts older than v3, see `exportGlossary`).
    struct Options: Sendable {
        let ownerName: String
        let glossary: [GlossaryEntry]
        let timeZone: TimeZone

        init(ownerName: String, glossary: [GlossaryEntry], timeZone: TimeZone) {
            self.ownerName = ownerName
            self.glossary = glossary
            self.timeZone = timeZone
        }

        init(config: ConfigValues, timeZone: TimeZone) {
            self.init(ownerName: config.hindsightOwnerName, glossary: config.glossary, timeZone: timeZone)
        }
    }

    var started: Date?
    var hasTranscript = false
    var words = 0
    var durationSeconds: Int?
    /// Only computed when there is something to compare it with — a v2
    /// `hindsight.json` or a `hindsight.error` — so a scan doesn't hash
    /// every transcript.
    var contentHash: String?
    /// v2 record only; nil when missing, malformed or v1 legacy.
    var sent: HindsightSentRecord?
    /// True only when `hindsight.error`'s hash matches the current content
    /// hash: a re-transcribed subscribed session is pending (waiting to be
    /// resent), not an error, even though the file is still on disk.
    var failed = false
    var request: HindsightRequestMarker?
    var skipped = false

    /// Sweeps in manual mode only look at these.
    var isSubscribed: Bool { request != nil || sent != nil }

    var isSentCurrent: Bool {
        guard let sent, let contentHash else { return false }
        return sent.contentHash == contentHash
    }

    func isShort(minWords: Int, minMinutes: Int) -> Bool {
        Self.isShort(words: words, durationSeconds: durationSeconds, minWords: minWords, minMinutes: minMinutes)
    }

    static func read(_ dir: URL, _ options: Options) -> HindsightFacts {
        let (facts0, entry, error, transcript) = readShared(dir)
        var facts = facts0
        guard let transcript else { return facts }
        if facts.sent != nil || error != nil, let started = entry.started,
           let text = try? HindsightPayloadBuilder.content(HindsightPayloadBuilder.turns(
               transcript.segments, started: started, ownerName: options.ownerName,
               glossary: HindsightPayloadBuilder.exportGlossary(options.glossary, glossaryApplied: transcript.glossaryApplied),
               timeZone: options.timeZone
           )) {
            facts.contentHash = HindsightPayloadBuilder.contentHash(text)
        }
        facts.failed = error != nil && error?.hash == facts.contentHash
        return facts
    }

    /// Cheap stand-in for `read(_:_:)`, for hot paths that can't afford
    /// building the full turn text and hashing it on every call — the
    /// sessions menu, rebuilt from `menuNeedsUpdate` every time it opens,
    /// unlike the main window's off-main-thread `MeetingIndex.scan`.
    /// Still decodes the transcript for `words`/`durationSeconds` (needed
    /// for the short-session check), but approximates "the sent record /
    /// error matches the current content" with file modification dates
    /// instead of a content hash: current if that file is at least as new
    /// as the transcript. Good enough for what the menu shows; a stale
    /// hash from a re-transcribed session may not be caught here until the
    /// main window (the precise source of truth) is opened.
    static func readCheap(_ dir: URL) -> HindsightFacts {
        let (facts0, _, error, transcript) = readShared(dir)
        var facts = facts0
        guard transcript != nil, let transcriptModified = modified(dir, SessionFiles.transcriptJSON) else { return facts }
        if let sent = facts.sent, let sentModified = modified(dir, SessionFiles.hindsightSent), sentModified >= transcriptModified {
            facts.contentHash = sent.contentHash
        }
        facts.failed = error != nil && (modified(dir, SessionFiles.hindsightError).map { $0 >= transcriptModified } ?? false)
        return facts
    }

    private static func readShared(
        _ dir: URL
    ) -> (facts: HindsightFacts, entry: MeetingEntry, error: HindsightErrorRecord?, transcript: TranscriptInput?) {
        let entry = MeetingEntry.load(dir)
        var facts = HindsightFacts(started: entry.started)
        facts.sent = readSent(dir)
        let error = readError(dir)
        facts.request = readRequest(dir)
        facts.skipped = SessionFiles.exists(SessionFiles.hindsightSkip, in: dir)
        guard let transcript = try? TranscriptInput.read(from: dir) else {
            facts.hasTranscript = SessionFiles.exists(SessionFiles.transcriptJSON, in: dir)
            facts.durationSeconds = entry.durationSeconds
            return (facts, entry, error, nil)
        }
        facts.hasTranscript = true
        facts.words = words(in: transcript.segments)
        facts.durationSeconds = duration(metaSeconds: entry.durationSeconds, segments: transcript.segments)
        return (facts, entry, error, transcript)
    }

    static func modified(_ dir: URL, _ name: String) -> Date? {
        (try? dir.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Short sessions

    static func words(in segments: [TranscriptInput.Segment]) -> Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// meta.json `duration_seconds`, else the end of the last segment (a
    /// recording cut short may never have written its duration).
    static func duration(metaSeconds: Int?, segments: [TranscriptInput.Segment]) -> Int? {
        if let metaSeconds { return metaSeconds }
        return segments.map { $0.end_ms ?? $0.start_ms }.max().map { $0 / 1000 }
    }

    /// Fewer words **or** fewer minutes than the thresholds.
    static func isShort(words: Int, durationSeconds: Int?, minWords: Int, minMinutes: Int) -> Bool {
        words < minWords || (durationSeconds ?? 0) < minMinutes * 60
    }

    // MARK: - Files

    /// Where a session's next send goes. Once sent, always the
    /// recorded bank — a record without one went to the default — so a
    /// session never moves; otherwise the bank of the outstanding request,
    /// then of the last rejection, then the default. Nil only when none is
    /// known (no default configured).
    static func targetBank(
        sent: HindsightSentRecord?, request: HindsightRequestMarker?, error: HindsightErrorRecord?,
        defaultBank: String?
    ) -> String? {
        // Values already come from tolerant decoders (blank → nil), but this
        // guards a caller passing a raw string directly, e.g. tests.
        if let sent { return normalizedBank(sent.bank) ?? normalizedBank(defaultBank) }
        return normalizedBank(request?.bank) ?? normalizedBank(error?.bank) ?? normalizedBank(defaultBank)
    }

    static func readSent(_ dir: URL) -> HindsightSentRecord? {
        guard let record = readJSON(HindsightSentRecord.self, dir, SessionFiles.hindsightSent),
              HindsightPayloadBuilder.isCurrentDocumentID(record.documentID)
        else { return nil }
        return record
    }

    /// A marker that exists but doesn't decode still counts as a plain request.
    static func readRequest(_ dir: URL) -> HindsightRequestMarker? {
        guard SessionFiles.exists(SessionFiles.hindsightRequested, in: dir) else { return nil }
        return readJSON(HindsightRequestMarker.self, dir, SessionFiles.hindsightRequested)
            ?? HindsightRequestMarker(force: false, requestedAt: nil)
    }

    static func readError(_ dir: URL) -> HindsightErrorRecord? {
        readJSON(HindsightErrorRecord.self, dir, SessionFiles.hindsightError)
    }

    static func writeJSON<T: Encodable>(_ value: T, _ dir: URL, _ name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, _ dir: URL, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
