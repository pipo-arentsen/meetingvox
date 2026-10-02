import CryptoKit
import Foundation

// MARK: - Session input

/// Everything one Hindsight request needs from a session folder, read once.
/// Pure data so the builder stays testable without files.
struct HindsightSessionInput: Sendable, Equatable {
    enum ReadError: Error, Equatable {
        /// Neither meta.json `started` nor the folder name parses.
        case noStartDate
        /// transcript.json is absent.
        case transcriptMissing
        /// transcript.json exists but doesn't decode.
        case transcriptCorrupt(String)
    }

    let name: String
    let started: Date
    let ended: Date?
    let durationSeconds: Int?
    let chosenTemplate: String?
    let summary: MeetingSummary?
    /// `minuta.md`, nil when absent. Read only for `asistentes`: the minutes
    /// never leave the Mac.
    let minutes: String?
    let transcriptEngine: String?
    let transcriptModel: String?
    let segments: [TranscriptInput.Segment]
    /// `text_raw` present: the transcript's text is already corrected, so the
    /// export must not apply the glossary again.
    var glossaryApplied = false
    /// meta.json `calendar_event`. Feeds only
    /// `titulo`, `asistentes` and the `context` sentence, never `content`, so
    /// the content hash and "already sent" never depend on it.
    var calendarEvent: CalendarEventRecord? = nil

    /// transcript.json as the transcription coordinator writes it; only the
    /// fields the export uses.
    private struct TranscriptFile: Decodable {
        let engine: String?
        let model: String?
        let segments: [TranscriptInput.Segment]
    }

    static func read(from dir: URL) throws -> HindsightSessionInput {
        let entry = MeetingEntry.load(dir)
        guard let started = entry.started else { throw ReadError.noStartDate }
        let meta = (try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard let transcriptData = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.transcriptJSON)) else {
            throw ReadError.transcriptMissing
        }
        let transcript: TranscriptFile
        do {
            transcript = try JSONDecoder().decode(TranscriptFile.self, from: transcriptData)
        } catch {
            throw ReadError.transcriptCorrupt("\(error)")
        }
        return HindsightSessionInput(
            name: dir.lastPathComponent,
            started: started,
            ended: (meta["ended"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            durationSeconds: entry.durationSeconds,
            chosenTemplate: SessionFiles.chosenMinutesTemplate(in: dir),
            summary: entry.summary,
            minutes: try? String(contentsOf: dir.appendingPathComponent(SessionFiles.minutes), encoding: .utf8),
            transcriptEngine: transcript.engine,
            transcriptModel: transcript.model,
            segments: transcript.segments,
            glossaryApplied: transcript.segments.contains { $0.text_raw != nil },
            calendarEvent: entry.calendarEvent
        )
    }
}

// MARK: - Wire format (Hindsight 0.10.1 `RetainRequest`)

/// One conversation turn inside `content`.
struct HindsightTurn: Encodable, Equatable, Sendable {
    let role: String
    let content: String
    let timestamp: String
}

struct HindsightMemoryItem: Encodable, Equatable, Sendable {
    let content: String
    let timestamp: String
    let context: String
    let metadata: [String: String]
    let documentID: String
    let tags: [String]
    let observationScopes: String
    let updateMode: String

    private enum CodingKeys: String, CodingKey {
        case content, timestamp, context, metadata, tags
        case documentID = "document_id"
        case observationScopes = "observation_scopes"
        case updateMode = "update_mode"
    }
}

struct HindsightRetainRequest: Encodable, Equatable, Sendable {
    let items: [HindsightMemoryItem]
    let isAsync: Bool
    /// Nil while hashing; the derived id afterwards.
    let operationID: String?

    private enum CodingKeys: String, CodingKey {
        case items
        case isAsync = "async"
        case operationID = "operation_id"
    }
}

// MARK: - Builder

struct HindsightBuildOptions: Sendable {
    let ownerName: String
    /// `hindsight.owner_description`; empty → the context repeats `ownerName`.
    let ownerDescription: String
    let glossary: [GlossaryEntry]
    let timeZone: TimeZone
    /// `minutes.template` from config (used when meta.json has no valid choice).
    let configTemplate: String
    /// Template id → display name (`TemplateStore`), nil when not found:
    /// only used to know whether a template exists, keeping the builder pure.
    let templateName: @Sendable (String) -> String?
    /// A forced resend: the request date that makes its
    /// `operation_id` new while keeping retries of that resend stable.
    var forcedAt: Date? = nil
}

struct HindsightPayload: Sendable, Equatable {
    /// The request body, with `operation_id`.
    let body: Data
    /// SHA-256 (lowercase hex) of the body **without** `operation_id`.
    let bodyHash: String
    /// SHA-256 of `content` only: what "already sent" means.
    let contentHash: String
    let operationID: String
    let documentID: String
}

/// Session → one `RetainRequest` with a single item: the transcript as JSON
/// turns (`mv-<session>`). Deterministic: same folder, same options → same
/// bytes. "Already sent" compares `contentHash` only, so regenerated minutes
/// or new metadata never resend; the normal `operation_id` derives from
/// the body so a retry of the same body is a no-op on the server, and a
/// forced resend mixes in its request date so Hindsight reprocesses it.
enum HindsightPayloadBuilder {
    static let sourceTag = "fuente:meetingvox"
    static let typeTag = "tipo:transcripcion"
    static let otherSpeakers = "Otros"
    static let documentPrefix = "mv-"

    static func documentID(session: String) -> String { documentPrefix + session }

    /// v2 document ids; anything else (v1 `quill-…`) is legacy.
    static func isCurrentDocumentID(_ id: String) -> Bool { id.hasPrefix(documentPrefix) }

    /// The glossary the export still applies itself: none for a
    /// transcript already corrected (its `text` is final; replacing again
    /// could rewrite a term's own text), and for transcripts older than v3
    /// only the entries flagged `transcript`, so their content — and what
    /// was already sent — matches what "Aplicar glosario" would produce.
    static func exportGlossary(_ glossary: [GlossaryEntry], glossaryApplied: Bool) -> [GlossaryEntry] {
        glossaryApplied ? [] : glossary.filter(\.transcript)
    }

    static func build(_ input: HindsightSessionInput, _ options: HindsightBuildOptions) throws -> HindsightPayload? {
        let conversation = turns(
            input.segments, started: input.started, ownerName: options.ownerName,
            glossary: exportGlossary(options.glossary, glossaryApplied: input.glossaryApplied),
            timeZone: options.timeZone
        )
        guard !conversation.isEmpty else { return nil }
        let text = try content(conversation)
        let template = templateID(input, options)
        var tags = [sourceTag, typeTag]
        if let template { tags.append("plantilla:\(template)") }
        // Tags sit outside `content`, so a change in client or country moves
        // `bodyHash` but never `contentHash` (no automatic resend; "Reenviar a
        // memoria" refreshes them).
        if let country = HindsightTagNormalizer.value(input.summary?.country) { tags.append("pais:\(country)") }
        if let client = HindsightTagNormalizer.value(input.summary?.client) { tags.append("cliente:\(client)") }
        let item = HindsightMemoryItem(
            content: text,
            timestamp: iso(input.started, options.timeZone),
            context: context(input, options),
            metadata: metadata(input, options, template: template),
            documentID: documentID(session: input.name),
            tags: tags,
            observationScopes: "shared",
            updateMode: "replace"
        )
        let bodyHash = hex(SHA256.hash(data: try encode(HindsightRetainRequest(items: [item], isAsync: true, operationID: nil))))
        let opID = options.forcedAt.map { forcedOperationID(bodyHash: bodyHash, forcedAt: $0) }
            ?? operationID(forHash: bodyHash)
        let body = try encode(HindsightRetainRequest(items: [item], isAsync: true, operationID: opID))
        return HindsightPayload(
            body: body, bodyHash: bodyHash, contentHash: contentHash(text), operationID: opID, documentID: item.documentID
        )
    }

    // MARK: Content

    /// Consecutive segments of one speaker merged into a turn (texts joined
    /// by a space); timestamp = session start + the turn's first `start_ms`,
    /// ISO 8601 with the local offset; `glossary` (already filtered by
    /// `exportGlossary`) applied to each turn; empty segments skipped before
    /// merging, empty turns dropped.
    static func turns(
        _ segments: [TranscriptInput.Segment], started: Date, ownerName: String,
        glossary: [GlossaryEntry], timeZone: TimeZone
    ) -> [HindsightTurn] {
        let replacer = GlossaryReplacer(glossary: glossary)
        var merged: [(speaker: String, startMS: Int, text: String)] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = merged.last, last.speaker == segment.speaker {
                merged[merged.count - 1].text += " " + text
            } else {
                merged.append((speaker: segment.speaker, startMS: segment.start_ms, text: text))
            }
        }
        return merged.compactMap { turn in
            let text = replacer.apply(turn.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return HindsightTurn(
                role: role(turn.speaker, owner: ownerName),
                content: text,
                timestamp: iso(started.addingTimeInterval(Double(turn.startMS) / 1000), timeZone)
            )
        }
    }

    /// The `content` string: sorted keys, `/` unescaped, so the hash is stable.
    static func content(_ turns: [HindsightTurn]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(turns), as: UTF8.self)
    }

    static func contentHash(_ content: String) -> String {
        hex(SHA256.hash(data: Data(content.utf8)))
    }

    // MARK: Operation ids

    /// UUID from the first 16 bytes of the hash, with the version (5) and
    /// RFC 4122 variant bits set so servers that validate UUIDs accept it.
    static func operationID(forHash hex: String) -> String {
        let chars = Array(hex.utf8)
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 where 2 * i + 1 < chars.count {
            b[i] = UInt8(String(decoding: chars[(2 * i)...(2 * i + 1)], as: UTF8.self), radix: 16) ?? 0
        }
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                               b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return uuid.uuidString.lowercased()
    }

    /// Forced resend: same body, new id, stable for that request date.
    static func forcedOperationID(bodyHash: String, forcedAt: Date) -> String {
        let seed = "\(bodyHash)|\(ISO8601DateFormatter().string(from: forcedAt))"
        return operationID(forHash: hex(SHA256.hash(data: Data(seed.utf8))))
    }

    // MARK: Metadata

    /// The session's template, "known" only when there are minutes or a
    /// choice in meta.json; resolution as in v1 (choice that still exists →
    /// config → `general`).
    static func templateID(_ input: HindsightSessionInput, _ options: HindsightBuildOptions) -> String? {
        guard input.minutes != nil || input.chosenTemplate != nil else { return nil }
        if let chosen = input.chosenTemplate, TemplateStore.isValidID(chosen), options.templateName(chosen) != nil {
            return chosen
        }
        if TemplateStore.isValidID(options.configTemplate), options.templateName(options.configTemplate) != nil {
            return options.configTemplate
        }
        return FactoryTemplates.general.id
    }

    /// Metadata: strings only, blank values dropped. The summary
    /// text, topics, participants and tasks are never sent; the client and
    /// country leave only as the normalized `cliente:`/`pais:` tags (see
    /// `build`), never as metadata values.
    private static func metadata(
        _ input: HindsightSessionInput, _ options: HindsightBuildOptions, template: String?
    ) -> [String: String] {
        let tz = options.timeZone
        var m: [String: String] = [:]
        m["titulo"] = displayTitle(input)
        m["fecha"] = formatter("yyyy-MM-dd", tz).string(from: input.started)
        m["hora_inicio"] = formatter("HH:mm", tz).string(from: input.started)
        m["hora_fin"] = input.ended.map { formatter("HH:mm", tz).string(from: $0) }
        m["duracion_min"] = input.durationSeconds.map { String(durationMinutes($0)) }
        m["zona_horaria"] = tz.identifier
        m["plantilla"] = template
        // Invitee names (the user out, nameless dropped, capped, never an
        // address) win over the names parsed from the minutes.
        let invitees = input.calendarEvent.map(CalendarInvitees.offMac) ?? []
        m["asistentes"] = invitees.isEmpty
            ? input.minutes.map { HindsightAttendees.parse(minutes: $0, templateID: template).joined(separator: ", ") }
            : invitees.joined(separator: ", ")
        m["motor_transcripcion"] = input.transcriptEngine
        m["modelo_transcripcion"] = input.transcriptModel
        m["modelo_resumen"] = input.summary?.model
        return m.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func context(_ input: HindsightSessionInput, _ options: HindsightBuildOptions) -> String {
        let tz = options.timeZone
        return HindsightPrompts.transcriptContext(
            title: displayTitle(input),
            day: formatter("yyyy-MM-dd", tz).string(from: input.started),
            start: formatter("HH:mm", tz).string(from: input.started),
            end: input.ended.map { formatter("HH:mm", tz).string(from: $0) },
            owner: options.ownerName,
            ownerDescription: options.ownerDescription
        )
    }

    /// The calendar event's title when linked, else the summary's (the same
    /// precedence as the app's display title, `SessionTitle`).
    private static func displayTitle(_ input: HindsightSessionInput) -> String? {
        SessionTitle.resolve(calendar: input.calendarEvent?.title, summary: input.summary?.title, header: nil)
    }

    private static func role(_ id: String, owner: String) -> String {
        switch id {
        case "me": owner
        case "them": otherSpeakers
        default: id
        }
    }

    private static func durationMinutes(_ seconds: Int) -> Int {
        seconds <= 0 ? 0 : max(1, Int((Double(seconds) / 60).rounded()))
    }

    private static func iso(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return f.string(from: date)
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    private static func encode(_ request: HindsightRetainRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Context text

/// Spanish `context` Hindsight's extractor reads (model-facing, like
/// `MinutesPrompts`, so not in `Textos`).
enum HindsightPrompts {
    static func transcriptContext(
        title: String?, day: String, start: String, end: String?, owner: String, ownerDescription: String
    ) -> String {
        let meeting = title.map { "la reunión \"\($0)\"" } ?? "la reunión"
        let hours = end.map { "\(start)–\($0)" } ?? start
        let description = ownerDescription.isEmpty ? owner : ownerDescription
        return "Transcripción de \(meeting) del \(day), \(hours). La pista \(owner) es \(description); "
            + "la pista \(HindsightPayloadBuilder.otherSpeakers) agrupa a todos los demás participantes."
    }
}
