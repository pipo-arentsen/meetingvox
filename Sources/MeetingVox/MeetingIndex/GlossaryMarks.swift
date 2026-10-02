import Foundation

/// One word (or run of words) the glossary changed in a transcript segment.
struct GlossaryMark: Equatable, Sendable {
    /// UTF-16 offset and length of the changed words inside the line's `text`.
    let location: Int
    let length: Int
    /// What the recognizer wrote there (`text_raw`), empty when words were added.
    let original: String
}

/// Finds what the glossary changed in a segment by diffing `text_raw` against
/// `text` word by word. Pure. It never re-runs the current glossary:
/// the marks describe what was written into `transcript.json`, even if the
/// glossary has changed since.
enum GlossaryMarks {
    /// A segment with more words than this on either side skips the diff (the
    /// LCS table is quadratic); it shows without marks, never as a failure.
    static let maxTokens = 400

    private struct Token {
        /// Word with its edge punctuation trimmed: what equality compares.
        let core: String
        /// UTF-16 range of `core` inside the source string.
        let range: NSRange
    }

    static func marks(raw: String?, text: String) -> [GlossaryMark] {
        guard let raw, raw != text else { return [] }
        let old = tokens(of: raw)
        let new = tokens(of: text)
        guard old.count <= maxTokens, new.count <= maxTokens else { return [] }

        let n = old.count, m = new.count
        // lcs[i][j] = length of the LCS of old[i...] and new[j...].
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = old[i].core == new[j].core ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var marks: [GlossaryMark] = []
        var i = 0, j = 0
        var gapOld: [Token] = [], gapNew: [Token] = []
        func flush() {
            defer { gapOld = []; gapNew = [] }
            guard let first = gapNew.first, let last = gapNew.last else { return }
            let start = first.range.location
            marks.append(GlossaryMark(
                location: start, length: last.range.location + last.range.length - start,
                original: join(gapOld, in: raw)
            ))
        }
        while i < n || j < m {
            if i < n, j < m, old[i].core == new[j].core {
                flush()
                i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                gapNew.append(new[j]); j += 1
            } else {
                gapOld.append(old[i]); i += 1
            }
        }
        flush()
        return marks
    }

    /// `«original» → replacement; …` for the line's hover; nil without marks.
    static func tooltip(_ marks: [GlossaryMark], in text: String) -> String? {
        guard !marks.isEmpty else { return nil }
        let ns = text as NSString
        return marks.map { mark in
            let now = ns.substring(with: NSRange(location: mark.location, length: mark.length))
            return "«\(mark.original)» → \(now)"
        }.joined(separator: "; ")
    }

    // MARK: - Tokens

    /// Whitespace-separated words whose edge punctuation is trimmed, so
    /// "vox," and "vox" are the same word and a punctuation-only
    /// edit is not a mark. Words that are only punctuation are dropped.
    private static func tokens(of s: String) -> [Token] {
        let ns = s as NSString
        var result: [Token] = []
        var start: Int? = nil
        func close(_ end: Int) {
            guard let from = start else { return }
            start = nil
            let word = ns.substring(with: NSRange(location: from, length: end - from))
            guard let core = trimmedRange(of: word) else { return }
            result.append(Token(
                core: (word as NSString).substring(with: core),
                range: NSRange(location: from + core.location, length: core.length)
            ))
        }
        var k = 0
        while k < ns.length {
            let ch = ns.character(at: k)
            if isSpace(ch) { close(k) } else if start == nil { start = k }
            k += 1
        }
        close(ns.length)
        return result
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// The UTF-16 range of `word` without leading/trailing punctuation, nil
    /// when nothing else is left.
    private static func trimmedRange(of word: String) -> NSRange? {
        let ns = word as NSString
        let keep = CharacterSet.alphanumerics
        var lo = 0, hi = ns.length
        func isWordChar(_ at: Int) -> Bool {
            let unit = ns.character(at: at)
            guard let scalar = Unicode.Scalar(unit) else { return true }   // surrogate halves: emoji etc. are content
            return keep.contains(scalar)
        }
        while lo < hi, !isWordChar(lo) { lo += 1 }
        while hi > lo, !isWordChar(hi - 1) { hi -= 1 }
        return lo < hi ? NSRange(location: lo, length: hi - lo) : nil
    }

    /// The original words of a gap, from the first token's start to the last
    /// one's end (inner punctuation and spacing kept as written).
    private static func join(_ gap: [Token], in raw: String) -> String {
        guard let first = gap.first, let last = gap.last else { return "" }
        let range = NSRange(location: first.range.location, length: last.range.location + last.range.length - first.range.location)
        return (raw as NSString).substring(with: range)
    }
}
