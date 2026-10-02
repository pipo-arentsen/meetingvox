import Foundation

/// What the index keeps of one session: its transcript lines (the very lines
/// the Transcripción tab draws, so a hit's `id` is a scroll target there) and
/// its minutes split into content lines, each with its folded form. Pure value.
struct FullTextDocument: Sendable, Equatable {
    struct Line: Sendable, Equatable {
        /// `TranscriptViewLine.id` for the transcript; the position among the
        /// minutes' content lines for the minutes.
        let id: Int
        let text: String
        /// `MeetingFilter.normalize(text)`.
        let folded: String
    }

    let transcript: [Line]
    let minutes: [Line]

    /// Whether any line of either source holds `token` (folded). Derived from
    /// the per-line folded forms, so the document keeps no second joined copy.
    func contains(_ token: String) -> Bool {
        transcript.contains { $0.folded.contains(token) } || minutes.contains { $0.folded.contains(token) }
    }

    static let empty = make(transcript: nil, minutes: nil)

    /// - Parameters:
    ///   - transcript: `TranscriptViewLines.load`; nil when there is none.
    ///   - minutes: `minuta.md` as text; nil without the file.
    static func make(transcript: [TranscriptViewLine]?, minutes: String?) -> FullTextDocument {
        let transcriptLines = (transcript ?? []).map {
            Line(id: $0.id, text: $0.text, folded: MeetingFilter.normalize($0.text))
        }
        let minutesLines = minutesContentLines(minutes ?? "").enumerated().map {
            Line(id: $0.offset, text: $0.element, folded: MeetingFilter.normalize($0.element))
        }
        return FullTextDocument(transcript: transcriptLines, minutes: minutesLines)
    }

    /// The minutes' searchable lines: no provenance header (a first line
    /// starting `<!-- quill minutes` is machinery, not content), no blank or
    /// rule lines, and markdown markers (`#`, `-`, `*`, `>`, table pipes)
    /// taken off so a snippet reads as text.
    static func minutesContentLines(_ text: String) -> [String] {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix(MarkdownBlocks.provenancePrefix) { lines.removeFirst() }
        return lines.compactMap { raw in
            var line = raw.replacingOccurrences(of: "|", with: " ")
            line = line.trimmingCharacters(in: .whitespaces)
            while let head = line.first, "#-*>".contains(head) {
                line.removeFirst()
            }
            line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }
}
