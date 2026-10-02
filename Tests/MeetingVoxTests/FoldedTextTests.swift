import Foundation
import Testing
@testable import MeetingVox

/// `FoldedText`: the same case/diacritic folding as `MeetingFilter.normalize`,
/// with a map back so a hit can be highlighted in the ORIGINAL text (UTF-16).
@Suite struct FoldedTextTests {
    private func cut(_ s: String, _ r: NSRange) -> String { (s as NSString).substring(with: r) }

    @Test func foldsLikeTheListFilter() {
        for s in ["Cotización FINAL", "Ñandú ÁÉÍ", "straße", "😀 Hola"] {
            #expect(FoldedText(s).folded == MeetingFilter.normalize(s), "\(s)")
        }
    }

    @Test func aTokenMapsBackToItsOriginalRange() {
        let text = "La Cotización final llegó"
        let ranges = FoldedText(text).originalRanges(of: "cotizacion")
        #expect(ranges.count == 1)
        #expect(cut(text, ranges[0]) == "Cotización")
    }

    @Test func everyOccurrenceIsFound() {
        let text = "ñoño y Ñoño"
        let ranges = FoldedText(text).originalRanges(of: "nono")
        #expect(ranges.map { cut(text, $0) } == ["ñoño", "Ñoño"])
    }

    @Test func offsetsAreUTF16AfterEmoji() {
        let text = "😀😀 acción"
        let ranges = FoldedText(text).originalRanges(of: "accion")
        #expect(ranges.count == 1)
        #expect(ranges[0].location == ("😀😀 " as NSString).length)
        #expect(cut(text, ranges[0]) == "acción")
    }

    @Test func aFoldThatChangesLengthStillMapsToWholeCharacters() {
        let text = "la Straße cerró"
        let ranges = FoldedText(text).originalRanges(of: "strasse")
        #expect(ranges.map { cut(text, $0) } == ["Straße"])
    }

    @Test func noOccurrenceAndEmptyTokenGiveNothing() {
        #expect(FoldedText("hola").originalRanges(of: "chao").isEmpty)
        #expect(FoldedText("hola").originalRanges(of: "").isEmpty)
    }
}
