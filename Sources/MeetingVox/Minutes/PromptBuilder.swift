import Foundation

// MARK: - Inputs

/// The slice of `transcript.json` the minutes pipeline reads. Decoded
/// separately from the coordinator's writer type so the minutes side only
/// depends on the stable schema keys, not on the transcription internals.
struct TranscriptInput: Sendable, Equatable, Decodable {
    struct Segment: Sendable, Equatable, Decodable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int?
        let text: String
        /// The recognizer's text before the glossary; nil in
        /// transcripts older than that.
        var text_raw: String? = nil
    }

    let segments: [Segment]

    /// The glossary already corrected `text` (at transcription or by
    /// "Aplicar glosario").
    var glossaryApplied: Bool { segments.contains { $0.text_raw != nil } }

    static func read(from dir: URL) throws -> TranscriptInput {
        let data = try Data(contentsOf: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        return try JSONDecoder().decode(TranscriptInput.self, from: data)
    }
}

/// Session metadata shown to the model. Every field but the name is
/// optional: an unreadable meta.json degrades the prompt, it doesn't fail it.
struct SessionInfo: Sendable, Equatable {
    let name: String
    let started: Date?
    let durationSeconds: Int?
    /// The linked calendar event's title and invitee names (names only, the
    /// user excluded, capped: `CalendarInvitees.offMac`), read when the job
    /// builds its prompt. Nil / empty = no event, and the prompt is byte for
    /// byte what it was before the calendar existed.
    var calendarTitle: String? = nil
    var invitees: [String] = []

    static func read(from dir: URL) -> SessionInfo {
        let url = dir.appendingPathComponent(SessionFiles.meta)
        let json = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let event = CalendarEventRecord(jsonObject: json[SessionFiles.metaCalendarEventKey])
        return SessionInfo(
            name: dir.lastPathComponent,
            started: (json["started"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            durationSeconds: json["duration_seconds"] as? Int,
            calendarTitle: event?.title,
            invitees: event.map(CalendarInvitees.offMac) ?? []
        )
    }
}

/// One rendered transcript line: consecutive segments of the same speaker
/// merged, keeping the first start and the last end.
struct TranscriptLine: Sendable, Equatable {
    let startMs: Int
    let endMs: Int
    let speaker: String
    let text: String

    var rendered: String {
        "[\(PromptBuilder.timestamp(startMs))] \(Textos.hablante(speaker)): \(text)"
    }
}

// MARK: - Builder

/// Pure prompt assembly (no I/O), so the exact text sent to the model is
/// testable. The Spanish copy lives in `MinutesPrompts`.
enum PromptBuilder {
    // MARK: Transcript lines

    /// Merge consecutive segments of the same speaker into one line. Saves
    /// tokens (one timestamp + label per turn instead of per ASR segment) and
    /// reads more like a dialogue. Blank segments are dropped.
    ///
    /// With `maxLineTokens`, no rendered line exceeds that estimate: a merge
    /// that would is started as a new line instead, and a single segment that
    /// alone is too long is split on whitespace (each piece keeps the
    /// segment's timestamps). The chunker never splits lines, so this is what
    /// keeps a long monologue from becoming one oversized chunk.
    static func lines(from segments: [TranscriptInput.Segment], maxLineTokens: Int? = nil) -> [TranscriptLine] {
        var result: [TranscriptLine] = []
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let end = seg.end_ms ?? seg.start_ms
            let pieces = maxLineTokens.map {
                split(text, maxCharacters: maxTextCharacters(maxTokens: $0, startMs: seg.start_ms, speaker: seg.speaker))
            } ?? [text]
            for piece in pieces {
                if let last = result.last, last.speaker == seg.speaker {
                    let merged = TranscriptLine(
                        startMs: last.startMs,
                        endMs: max(last.endMs, end),
                        speaker: last.speaker,
                        text: last.text + " " + piece
                    )
                    if maxLineTokens.map({ Chunker.estimateTokens(merged.rendered) <= $0 }) ?? true {
                        result[result.count - 1] = merged
                        continue
                    }
                }
                result.append(TranscriptLine(startMs: seg.start_ms, endMs: end, speaker: seg.speaker, text: piece))
            }
        }
        return result
    }

    /// Characters of text that fit in a line of `maxTokens` once the
    /// `[mm:ss] Speaker: ` prefix is counted. At least 1.
    private static func maxTextCharacters(maxTokens: Int, startMs: Int, speaker: String) -> Int {
        let prefix = TranscriptLine(startMs: startMs, endMs: startMs, speaker: speaker, text: "").rendered.count
        return max(1, Int(Double(maxTokens) * 3.5) - prefix)
    }

    /// Greedy whitespace split of `text` into pieces of at most
    /// `maxCharacters`; a single word longer than that is cut by characters.
    static func split(_ text: String, maxCharacters: Int) -> [String] {
        guard text.count > maxCharacters else { return [text] }
        var pieces: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            var word = Substring(word)
            while word.count > maxCharacters {
                if !current.isEmpty { pieces.append(current); current = "" }
                pieces.append(String(word.prefix(maxCharacters)))
                word = word.dropFirst(maxCharacters)
            }
            guard !word.isEmpty else { continue }
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= maxCharacters {
                current += " " + word
            } else {
                pieces.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// `mm:ss`, or `h:mm:ss` from one hour on.
    static func timestamp(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// Duration as `h:mm` (seconds truncated).
    static func duration(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// Long Spanish date, e.g. "miércoles, 23 de septiembre de 2026, 10:05".
    static func startDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es")
        f.timeZone = timeZone
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: Messages

    /// System prompt for the final minutes: role, template, output language,
    /// optional glossary, and the "the transcript is automatic" caveat.
    static func systemPrompt(template: MinutesTemplate, language: String, glossary: [GlossaryEntry]) -> String {
        var parts = [
            MinutesPrompts.rol,
            MinutesPrompts.instruccionesPlantilla + "\n\n" + template.cuerpo,
            MinutesPrompts.idioma(language),
        ]
        if let block = MinutesPrompts.glosarioBloque(glossary) { parts.append(block) }
        parts.append(MinutesPrompts.aviso)
        return parts.joined(separator: "\n\n")
    }

    /// Session metadata block that opens every user message.
    static func metadata(_ info: SessionInfo, timeZone: TimeZone = .current) -> String {
        var rows = [MinutesPrompts.encabezadoMetadatos, MinutesPrompts.sesion(info.name)]
        if let started = info.started {
            rows.append(MinutesPrompts.inicio(startDate(started, timeZone: timeZone)))
        }
        if let seconds = info.durationSeconds {
            rows.append(MinutesPrompts.duracion(duration(seconds)))
        }
        // Every call that sends context goes through here (single call, chunk
        // notes, reductions, consolidation), so they all carry the event.
        rows += MinutesPrompts.eventoCalendario(title: info.calendarTitle, invitees: info.invitees)
        return rows.joined(separator: "\n")
    }

    /// Single-call user message: metadata + the whole transcript.
    static func userPrompt(info: SessionInfo, lines: [TranscriptLine], timeZone: TimeZone = .current) -> String {
        metadata(info, timeZone: timeZone) + "\n\n" + MinutesPrompts.encabezadoTranscripcion + "\n"
            + lines.map(\.rendered).joined(separator: "\n")
    }

    /// System prompt for one chunk's partial notes. The glossary matters most
    /// here, where names are first read from the raw transcript.
    static func partialSystemPrompt(
        part: Int, of total: Int, lines: [TranscriptLine], language: String, glossary: [GlossaryEntry]
    ) -> String {
        var parts = [
            MinutesPrompts.rolParcial,
            MinutesPrompts.instruccionesParcial(
                parte: part, de: total,
                desde: timestamp(lines.first?.startMs ?? 0),
                hasta: timestamp(lines.last?.endMs ?? 0)
            ),
            MinutesPrompts.idioma(language),
        ]
        if let block = MinutesPrompts.glosarioBloque(glossary) { parts.append(block) }
        parts.append(MinutesPrompts.aviso)
        return parts.joined(separator: "\n\n")
    }

    static func partialUserPrompt(
        info: SessionInfo, part: Int, of total: Int, lines: [TranscriptLine], timeZone: TimeZone = .current
    ) -> String {
        metadata(info, timeZone: timeZone) + "\n\n" + MinutesPrompts.encabezadoFragmento(parte: part, de: total) + "\n"
            + lines.map(\.rendered).joined(separator: "\n")
    }

    /// Consolidation user message: metadata + every chunk's notes, in order.
    static func consolidationUserPrompt(info: SessionInfo, notes: [String], timeZone: TimeZone = .current) -> String {
        var parts = [metadata(info, timeZone: timeZone), MinutesPrompts.introConsolidacion]
        parts += numberedNotes(notes, firstPart: 1, total: notes.count)
        return parts.joined(separator: "\n\n")
    }

    /// System prompt for condensing a group of consecutive notes (parts
    /// `from`…`to` of `total`) when all notes together don't fit the
    /// consolidation call.
    static func reductionSystemPrompt(from: Int, to: Int, of total: Int, language: String, glossary: [GlossaryEntry]) -> String {
        var parts = [
            MinutesPrompts.rolReduccion,
            MinutesPrompts.instruccionesReduccion(desde: from, hasta: to, de: total),
            MinutesPrompts.idioma(language),
        ]
        if let block = MinutesPrompts.glosarioBloque(glossary) { parts.append(block) }
        return parts.joined(separator: "\n\n")
    }

    static func reductionUserPrompt(
        info: SessionInfo, notes: [String], firstPart: Int, total: Int, timeZone: TimeZone = .current
    ) -> String {
        ([metadata(info, timeZone: timeZone)] + numberedNotes(notes, firstPart: firstPart, total: total))
            .joined(separator: "\n\n")
    }

    private static func numberedNotes(_ notes: [String], firstPart: Int, total: Int) -> [String] {
        notes.enumerated().map { i, note in
            MinutesPrompts.encabezadoNotas(parte: firstPart + i, de: total) + "\n" + note
        }
    }
}
