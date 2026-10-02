import Foundation

/// Inline markdown (`**bold**`, `*italic*`, `` `code` ``, links) for one
/// block's text. Block structure is `MarkdownBlocks`' job, so only the inline
/// syntax is interpreted (`.inlineOnlyPreservingWhitespace` keeps line breaks
/// and spacing). Never throws: if the system parser rejects the text it falls
/// back to the text as written.
///
/// Minutes text comes from an LLM summarising a transcript, so a link in it is
/// untrusted: only `http`, `https` and `mailto` stay clickable. Any other
/// scheme (`file:`, `ssh:`, app schemes, `javascript:`) or a relative target
/// renders as its plain label.
enum MarkdownInline {
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var result = try? AttributedString(markdown: text, options: options) else { return plain(text) }
        let blocked = result.runs.compactMap { run in
            run.link.flatMap { isAllowedLink($0) ? nil : run.range }
        }
        for range in blocked { result[range].link = nil }
        return result
    }

    static func plain(_ text: String) -> AttributedString {
        AttributedString(text)
    }

    /// Also the guard for `MarkdownDocumentView`'s `openURL` action.
    static func isAllowedLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedLinkSchemes.contains(scheme)
    }
}
