import Foundation
import Testing
@testable import MeetingVox

@Suite struct MarkdownParseCacheTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func cache(counting counter: Counter) -> MarkdownParseCache {
        MarkdownParseCache { text in
            counter.increment()
            return MarkdownBlocks.parse(text)
        }
    }

    @Test func theSameTextIsParsedOnce() {
        let counter = Counter()
        let cache = cache(counting: counter)

        let first = cache.blocks(for: "# A\n\ntexto")
        let second = cache.blocks(for: "# A\n\ntexto")

        #expect(counter.count == 1)
        #expect(first == second)
        #expect(first == [.heading(level: 1, text: "A"), .paragraph("texto")])
    }

    @Test func differentTextsAreParsedSeparatelyAndReturnTheirOwnBlocks() {
        let counter = Counter()
        let cache = cache(counting: counter)

        let a = cache.blocks(for: "# A")
        let b = cache.blocks(for: "# B")
        _ = cache.blocks(for: "# A")

        #expect(counter.count == 2)
        #expect(a == [.heading(level: 1, text: "A")])
        #expect(b == [.heading(level: 1, text: "B")])
    }

    @Test func anEmptyTextIsCachedToo() {
        let counter = Counter()
        let cache = cache(counting: counter)

        #expect(cache.blocks(for: "").isEmpty)
        #expect(cache.blocks(for: "").isEmpty)
        #expect(counter.count == 1)
    }
}
