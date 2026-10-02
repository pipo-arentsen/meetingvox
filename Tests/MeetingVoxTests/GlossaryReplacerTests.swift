import Foundation
import Testing
@testable import MeetingVox

@Suite struct GlossaryReplacerTests {
    private let glossary = [
        GlossaryEntry(term: "MeetingVox", variants: ["miting vox", "mitin vox"]),
        GlossaryEntry(term: "Kafka", variants: ["kafca"]),
        GlossaryEntry(term: "Kubernetes"),
    ]

    @Test func replacesVariantsWithTheirTerm() {
        #expect(GlossaryReplacer(glossary: glossary).apply("Hablamos con miting vox y kafca.")
            == "Hablamos con MeetingVox y Kafka.")
    }

    @Test func matchingIgnoresCase() {
        #expect(GlossaryReplacer(glossary: glossary).apply("Miting Vox y KAFCA") == "MeetingVox y Kafka")
    }

    @Test func onlyWholeWordsAreReplaced() {
        let text = "kafcas akafca kafca_x kafca2"
        #expect(GlossaryReplacer(glossary: glossary).apply(text) == text)
    }

    @Test func punctuationAndLineEdgesAreBoundaries() {
        #expect(GlossaryReplacer(glossary: glossary).apply("kafca,\n(miting vox)") == "Kafka,\n(MeetingVox)")
    }

    @Test func longerVariantWinsOverOverlappingShorterOne() {
        let r = GlossaryReplacer(glossary: [
            GlossaryEntry(term: "Vox", variants: ["bocs"]),
            GlossaryEntry(term: "Meeting Vox", variants: ["miting la bocs"]),
        ])
        #expect(r.apply("el miting la bocs y la bocs") == "el Meeting Vox y la Vox")
    }

    @Test func metacharactersAreLiteral() {
        let r = GlossaryReplacer(glossary: [GlossaryEntry(term: "$1 C++", variants: ["c.más(+)"])])
        #expect(r.apply("uso c.más(+) y cxmás(+)") == "uso $1 C++ y cxmás(+)")
    }

    @Test func replacementsDoNotCascade() {
        let r = GlossaryReplacer(glossary: [
            GlossaryEntry(term: "Beta", variants: ["alfa"]),
            GlossaryEntry(term: "Gamma", variants: ["beta"]),
        ])
        #expect(r.apply("alfa beta") == "Beta Gamma")
    }

    @Test func noVariantsLeavesTextUntouched() {
        #expect(GlossaryReplacer(glossary: [GlossaryEntry(term: "Kubernetes")]).apply("kubernetes") == "kubernetes")
        #expect(GlossaryReplacer(glossary: []).apply("miting vox") == "miting vox")
    }

    @Test func countsReplacements() {
        let r = GlossaryReplacer(glossary: glossary)
        let result = r.applyCounting("miting vox, kafca y Miting Vox")
        #expect(result.text == "MeetingVox, Kafka y MeetingVox")
        #expect(result.replacements == 3)
        #expect(r.applyCounting("nada que ver").replacements == 0)
        #expect(GlossaryReplacer(glossary: []).applyCounting("miting vox").replacements == 0)
    }

    @Test func forTranscriptSkipsEntriesWithTheFlagOff() {
        let r = GlossaryReplacer.forTranscript([
            GlossaryEntry(term: "MeetingVox", variants: ["miting vox"]),
            GlossaryEntry(term: "Kafka", variants: ["kafca"], transcript: false),
        ])
        #expect(r.apply("miting vox y kafca") == "MeetingVox y kafca")
    }
}
