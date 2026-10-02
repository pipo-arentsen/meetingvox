import Foundation

/// Parsed blocks keyed by the markdown text, so a SwiftUI body that
/// re-evaluates with the same `minuta.md` does not re-parse it. The parser is
/// a seam only so a test can count calls.
final class MarkdownParseCache: @unchecked Sendable {
    /// `NSCache` needs reference values and evicts under memory pressure.
    private final class Entry {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    static let shared = MarkdownParseCache()

    private let parse: @Sendable (String) -> [MarkdownBlock]
    private let cache = NSCache<NSString, Entry>()

    init(countLimit: Int = 32, parse: @escaping @Sendable (String) -> [MarkdownBlock] = MarkdownBlocks.parse) {
        self.parse = parse
        cache.countLimit = countLimit
    }

    func blocks(for text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = parse(text)
        cache.setObject(Entry(blocks), forKey: key)
        return blocks
    }
}
