import Foundation
import Testing
@testable import MeetingVox

/// Glossary marks: the words the glossary changed in a segment, found
/// by diffing `text_raw` against `text` word by word, as UTF-16 ranges into
/// `text` (what `NSRange`/`AttributedString` want). The current glossary is
/// never re-run: the marks reflect what was written.
@Suite struct GlossaryMarksTests {
    private func substring(_ text: String, _ mark: GlossaryMark) -> String {
        (text as NSString).substring(with: NSRange(location: mark.location, length: mark.length))
    }

    @Test func identicalTextHasNoMarks() {
        #expect(GlossaryMarks.marks(raw: "miting vox abrió", text: "miting vox abrió").isEmpty)
    }

    @Test func aMissingRawMeansNoMarks() {
        #expect(GlossaryMarks.marks(raw: nil, text: "MeetingVox abrió").isEmpty)
    }

    @Test func oneWordReplacingTwoIsOneMarkWithTheOriginalWords() {
        let text = "MeetingVox abrió"
        let marks = GlossaryMarks.marks(raw: "miting vox abrió", text: text)
        #expect(marks.count == 1)
        #expect(substring(text, marks[0]) == "MeetingVox")
        #expect(marks[0].original == "miting vox")
    }

    @Test func oneWordReplacingOneWordAndMultiWordReplacement() {
        let text = "Quill Meeting Vox funciona"
        let marks = GlossaryMarks.marks(raw: "quil mitin funciona", text: text)
        #expect(marks.count == 1)
        #expect(substring(text, marks[0]) == "Quill Meeting Vox")
        #expect(marks[0].original == "quil mitin")
    }

    @Test func severalSeparateChangesAreSeparateMarks() {
        let text = "MeetingVox pidió Grafana hoy"
        let marks = GlossaryMarks.marks(raw: "miting vox pidió gra fana hoy", text: text)
        #expect(marks.map { substring(text, $0) } == ["MeetingVox", "Grafana"])
        #expect(marks.map(\.original) == ["miting vox", "gra fana"])
    }

    @Test func punctuationAroundAChangedWordStaysOutOfTheMark() {
        let text = "Con MeetingVox, abrió."
        let marks = GlossaryMarks.marks(raw: "Con miting vox, abrió.", text: text)
        #expect(marks.count == 1)
        #expect(substring(text, marks[0]) == "MeetingVox")
        #expect(marks[0].original == "miting vox")
    }

    @Test func aPunctuationOnlyDifferenceIsNotAMark() {
        #expect(GlossaryMarks.marks(raw: "hola, mundo", text: "hola mundo.").isEmpty)
    }

    @Test func offsetsAreUTF16AfterAccentsAndEmoji() {
        let text = "😀 Ñandú MeetingVox abrió"
        let marks = GlossaryMarks.marks(raw: "😀 Ñandú miting vox abrió", text: text)
        #expect(marks.count == 1)
        #expect(marks[0].location == ("😀 Ñandú " as NSString).length)
        #expect(substring(text, marks[0]) == "MeetingVox")
    }

    @Test func aCaseOnlyChangeIsMarked() {
        let text = "hablé con MeetingVox"
        let marks = GlossaryMarks.marks(raw: "hablé con meetingvox", text: text)
        #expect(marks.map { substring(text, $0) } == ["MeetingVox"])
        #expect(marks[0].original == "meetingvox")
    }

    @Test func aSegmentOverFourHundredTokensSkipsTheDiffWithoutFailing() {
        let raw = (0..<401).map { _ in "palabra" }.joined(separator: " ")
        let text = "X " + raw
        #expect(GlossaryMarks.marks(raw: raw, text: text).isEmpty)
        let ok = (0..<399).map { _ in "palabra" }.joined(separator: " ")
        #expect(GlossaryMarks.marks(raw: "a " + ok, text: "b " + ok).count == 1,
                "400 tokens on both sides still diffs")
    }

    @Test func tooltipListsOriginalsAndTheirReplacements() {
        let text = "MeetingVox pidió Grafana hoy"
        let marks = GlossaryMarks.marks(raw: "miting vox pidió gra fana hoy", text: text)
        #expect(GlossaryMarks.tooltip(marks, in: text) == "«miting vox» → MeetingVox; «gra fana» → Grafana")
        #expect(GlossaryMarks.tooltip([], in: text) == nil)
    }
}
