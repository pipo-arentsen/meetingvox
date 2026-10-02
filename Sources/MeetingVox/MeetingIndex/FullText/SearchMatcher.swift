import Foundation

/// The line a full-text hit points at, with the text to show for it.
struct SearchSnippet: Equatable, Sendable {
    /// About 120 characters cut around the first highlight, with "…" where cut.
    let text: String
    /// UTF-16 ranges into `text` of every query token found in it.
    let highlights: [NSRange]
}

/// A session matched through its transcript or minutes text.
struct SearchHit: Equatable, Sendable {
    enum Source: Equatable, Sendable { case transcript, minutes }
    let source: Source
    /// `TranscriptViewLine.id` (the tab scrolls to it) or the minutes line
    /// position (the Minuta tab just opens).
    let lineID: Int
    let snippet: SearchSnippet
}

/// AND-of-tokens over metadata ∪ transcript ∪ minutes, and the snippet rule.
/// Pure.
enum SearchMatcher {
    enum Outcome: Equatable, Sendable {
        case none
        /// The summary fields alone satisfy every token: the row needs no snippet.
        case metadata
        case hit(SearchHit)
    }

    static let snippetLength = 120

    /// Folded, space-split query tokens (the list filter's own rule).
    static func tokens(of query: String) -> [String] {
        MeetingFilter.normalize(query).split(separator: " ").map(String.init)
    }

    /// - Parameter metadata: the raw `MeetingFilter.haystackText` (folded here).
    static func match(tokens: [String], metadata: String, document: FullTextDocument) -> Outcome {
        guard !tokens.isEmpty else { return .none }
        let foldedMetadata = MeetingFilter.normalize(metadata)
        let missingFromMetadata = tokens.filter { !foldedMetadata.contains($0) }
        if missingFromMetadata.isEmpty { return .metadata }
        // Every token must live somewhere; a session with a token nowhere is hidden.
        for token in missingFromMetadata where !document.contains(token) {
            return .none
        }

        // Rev 2: a transcript line holding ALL tokens, else a minutes line
        // holding all, else the first line (transcript first) with a token the
        // metadata could not supply.
        if let line = document.transcript.first(where: { containsAll(tokens, in: $0.folded) }) {
            return .hit(hit(.transcript, line, tokens))
        }
        if let line = document.minutes.first(where: { containsAll(tokens, in: $0.folded) }) {
            return .hit(hit(.minutes, line, tokens))
        }
        if let line = document.transcript.first(where: { containsAny(missingFromMetadata, in: $0.folded) }) {
            return .hit(hit(.transcript, line, tokens))
        }
        if let line = document.minutes.first(where: { containsAny(missingFromMetadata, in: $0.folded) }) {
            return .hit(hit(.minutes, line, tokens))
        }
        return .none
    }

    private static func containsAll(_ tokens: [String], in folded: String) -> Bool {
        tokens.allSatisfy { folded.contains($0) }
    }

    private static func containsAny(_ tokens: [String], in folded: String) -> Bool {
        tokens.contains { folded.contains($0) }
    }

    private static func hit(_ source: SearchHit.Source, _ line: FullTextDocument.Line, _ tokens: [String]) -> SearchHit {
        SearchHit(source: source, lineID: line.id, snippet: snippet(of: line.text, tokens: tokens))
    }

    // MARK: - Snippet

    /// Whole line when it fits in `snippetLength`; else that many characters
    /// starting a little before the first highlight, on character boundaries.
    static func snippet(of text: String, tokens: [String]) -> SearchSnippet {
        let folded = FoldedText(text)
        let highlights = tokens.flatMap { folded.originalRanges(of: $0) }.sorted { $0.location < $1.location }
        let ns = text as NSString
        guard ns.length > snippetLength else { return SearchSnippet(text: text, highlights: highlights) }

        let lead = 30
        var start = max(0, (highlights.first?.location ?? 0) - lead)
        var end = min(ns.length, start + snippetLength)
        if end == ns.length { start = max(0, end - snippetLength) }
        start = ns.rangeOfComposedCharacterSequence(at: start).location
        let endRange = ns.rangeOfComposedCharacterSequence(at: max(0, end - 1))
        end = endRange.location + endRange.length

        let prefix = start > 0 ? "…" : ""
        let suffix = end < ns.length ? "…" : ""
        let body = ns.substring(with: NSRange(location: start, length: end - start))
        let shift = prefix.utf16.count - start
        let clipped = highlights.compactMap { r -> NSRange? in
            let lo = max(r.location, start), hi = min(r.location + r.length, end)
            return hi > lo ? NSRange(location: lo + shift, length: hi - lo) : nil
        }
        return SearchSnippet(text: prefix + body + suffix, highlights: clipped)
    }
}
