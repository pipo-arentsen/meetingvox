import Foundation
import Testing
@testable import MeetingVox

@Suite struct SidebarCountsTests {
    private func entries() -> [MeetingEntry] {
        [
            makeEntry("a", ambito: .trabajo), makeEntry("b", ambito: .trabajo), makeEntry("c", ambito: .trabajo),
            makeEntry("d", ambito: .profesional),
            makeEntry("e", ambito: .personal), makeEntry("f", ambito: .personal),
            makeEntry("g"), makeEntry("h"), makeEntry("i"), makeEntry("j"),
        ]
    }

    @Test func countsEveryAmbitoAndTheTotal() {
        let counts = SidebarCounts(entries())

        #expect(counts.total == 10)
        #expect(counts.count(.only(.trabajo)) == 3)
        #expect(counts.count(.only(.profesional)) == 1)
        #expect(counts.count(.only(.personal)) == 2)
        #expect(counts.count(.unclassified) == 4)
        #expect(counts.count(.all) == 10)
    }

    @Test func ambitoCountsAddUpToTheTotal() {
        let counts = SidebarCounts(entries())
        let sum = Ambito.allCases.map { counts.count(.only($0)) }.reduce(0, +) + counts.count(.unclassified)

        #expect(sum == counts.total)
    }

    @Test func anEmptyRootHasZeroEverywhere() {
        let counts = SidebarCounts([])

        #expect(counts.total == 0)
        #expect(counts.count(.only(.trabajo)) == 0)
        #expect(counts.count(.unclassified) == 0)
    }

    @Test func countsSeeEveryEntryNotJustTheOnesTheListShows() {
        // The sidebar is fed the full scan, before any window or filter.
        let all = (0..<50).map { makeEntry("s\($0)", ambito: $0 % 2 == 0 ? .trabajo : nil) }

        let counts = SidebarCounts(all)

        #expect(counts.count(.only(.trabajo)) == 25)
        #expect(counts.count(.unclassified) == 25)
    }
}
