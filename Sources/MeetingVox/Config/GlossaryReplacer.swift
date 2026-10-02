import Foundation

/// Rewrites known mis-transcriptions (glossary `variants`) to their correct
/// `term` — whole words only, case-insensitive, longest variant first, in
/// one pass so a replacement is never rewritten again by another entry.
/// Used on the transcript itself after transcription and by "Aplicar
/// glosario" (`TranscriptGlossary`, flagged entries only), and on the copy
/// sent to Hindsight of transcripts older than that (`exportGlossary`).
struct GlossaryReplacer {
    private let regex: NSRegularExpression?
    /// Lowercased variant → term. The first entry wins for a variant listed twice.
    private let terms: [String: String]

    init(glossary: [GlossaryEntry]) {
        var map: [String: String] = [:]
        for entry in glossary {
            for variant in entry.variants where map[variant.lowercased()] == nil {
                map[variant.lowercased()] = entry.term
            }
        }
        terms = map
        // Longest first: at a given position the alternation takes the first
        // branch that matches, so "miting vox pro" beats "miting vox".
        let variants = map.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        regex = variants.isEmpty ? nil : try? NSRegularExpression(
            pattern: Self.wholeWord(variants.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")),
            options: [.caseInsensitive]
        )
    }

    /// Only the entries flagged "Corregir en la transcripción".
    static func forTranscript(_ glossary: [GlossaryEntry]) -> GlossaryReplacer {
        GlossaryReplacer(glossary: glossary.filter(\.transcript))
    }

    func apply(_ text: String) -> String { applyCounting(text).text }

    /// The rewritten text and how many variants were replaced (for logs).
    func applyCounting(_ text: String) -> (text: String, replacements: Int) {
        guard let regex else { return (text, 0) }
        let ns = text as NSString
        var result = ""
        var last = 0
        var count = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let found = ns.substring(with: match.range)
            // Built by hand (not a regex template), so `$` in a term is literal.
            result += terms[found.lowercased()] ?? found
            last = match.range.location + match.range.length
            count += 1
        }
        return (result + ns.substring(from: last), count)
    }

    /// Letters, digits and `_` on either side mean "inside a word".
    private static func wholeWord(_ alternation: String) -> String {
        #"(?<![\p{L}\p{N}_])(?:"# + alternation + #")(?![\p{L}\p{N}_])"#
    }
}
