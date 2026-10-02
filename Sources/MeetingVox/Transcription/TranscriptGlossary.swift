import Foundation

/// The glossary applied to a transcript: only entries flagged
/// `transcript`, always from the original text (`text_raw`, or `text` for a
/// transcript that has none yet) — so running it again, or after the
/// glossary changed, never compounds. Minutes and summaries are never
/// touched: they read the corrected `text` next time they're generated.
enum TranscriptGlossary {
    struct Result: Equatable {
        let segments: [TranscriptDocument.Segment]
        let replacements: Int
    }

    enum Outcome: Equatable, Sendable {
        /// Nothing to change; the files were not rewritten.
        case unchanged
        case rewritten(replacements: Int)
    }

    /// Pure. Every segment gets `text_raw` (the original) and `text`
    /// (corrected).
    static func apply(_ segments: [TranscriptDocument.Segment], glossary: [GlossaryEntry]) -> Result {
        let replacer = GlossaryReplacer.forTranscript(glossary)
        var total = 0
        let corrected = segments.map { segment -> TranscriptDocument.Segment in
            let raw = segment.text_raw ?? segment.text
            let (text, count) = replacer.applyCounting(raw)
            total += count
            var copy = segment
            copy.text = text
            copy.text_raw = raw
            return copy
        }
        return Result(segments: corrected, replacements: total)
    }

    /// "Aplicar glosario": reapply `glossary` to `dir`'s transcript and
    /// rewrite transcript.json + transcript.md — only when some `text`
    /// changes. An unchanged file keeps its modification date, which the
    /// sessions menu uses to tell a transcript already in memory from a
    /// changed one (`HindsightFacts.readCheap`).
    static func reapply(in dir: URL, glossary: [GlossaryEntry]) throws -> Outcome {
        var document = try TranscriptDocument.read(from: dir)
        let result = apply(document.segments, glossary: glossary)
        guard result.segments.map(\.text) != document.segments.map(\.text) else { return .unchanged }
        document.segments = result.segments
        try document.write(to: dir)
        return .rewritten(replacements: result.replacements)
    }
}
