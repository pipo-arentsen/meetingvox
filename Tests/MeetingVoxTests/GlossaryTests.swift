import Foundation
import Testing
@testable import MeetingVox

@Suite struct GlossaryEntryTests {
    // MARK: Parsing

    @Test func plainStringsAreTermsWithoutVariants() {
        let v = ConfigValues(raw: ["glossary": [" Grafana ", "Kubernetes"]])
        #expect(v.glossary == [GlossaryEntry(term: "Grafana"), GlossaryEntry(term: "Kubernetes")])
    }

    @Test func objectsCarryVariants() {
        let v = ConfigValues(raw: ["glossary": [
            ["term": "MeetingVox", "variants": ["miting vox", " mitin vox "]],
        ]])
        #expect(v.glossary == [GlossaryEntry(term: "MeetingVox", variants: ["miting vox", "mitin vox"])])
    }

    @Test func mixedStringsAndObjectsKeepOrder() {
        let v = ConfigValues(raw: ["glossary": [
            "Kubernetes",
            ["term": "Kafka", "variants": ["cafca", "kafca"]],
            "Grafana",
        ]])
        #expect(v.glossary.map(\.term) == ["Kubernetes", "Kafka", "Grafana"])
        #expect(v.glossary[1].variants == ["cafca", "kafca"])
    }

    @Test func malformedElementsAreIgnored() {
        let v = ConfigValues(raw: ["glossary": [
            42,
            "",
            "   ",
            ["variants": ["x"]],
            ["term": 3],
            ["term": "  "],
            ["term": "Ok", "variants": "not an array"],
            ["term": "Mixed", "variants": ["bien", 7, "", "  "]],
            [1, 2],
        ]])
        #expect(v.glossary == [
            GlossaryEntry(term: "Ok"),
            GlossaryEntry(term: "Mixed", variants: ["bien"]),
        ])
    }

    @Test func nonArrayGlossaryIsEmpty() {
        #expect(ConfigValues(raw: ["glossary": "Grafana"]).glossary == [])
    }

    @Test func variantsDedupeCaseInsensitivelyAndDropTheTermItself() {
        let v = ConfigValues(raw: ["glossary": [
            ["term": "Kafka", "variants": ["cafca", "Cafca", "KAFCA", "kafca", "kafka"]],
        ]])
        #expect(v.glossary == [GlossaryEntry(term: "Kafka", variants: ["cafca", "KAFCA"])])
    }

    @Test func duplicateTermsMergeIntoTheFirst() {
        let v = ConfigValues(raw: ["glossary": [
            "Kafka",
            ["term": "kafka", "variants": ["cafca"]],
        ]])
        #expect(v.glossary == [GlossaryEntry(term: "Kafka", variants: ["cafca"])])
    }

    // MARK: Transcript flag

    @Test func transcriptFlagDefaultsToTrue() {
        let v = ConfigValues(raw: ["glossary": [
            "Grafana",
            ["term": "MeetingVox", "variants": ["miting vox"]] as [String: Any],
            ["term": "Kafka", "variants": ["kafca"], "transcript": false] as [String: Any],
            ["term": "Ok", "transcript": "no"] as [String: Any],
        ]])
        #expect(v.glossary.map(\.transcript) == [true, true, false, true])
        #expect(v.glossary[2] == GlossaryEntry(term: "Kafka", variants: ["kafca"], transcript: false))
    }

    @Test func duplicateTermsKeepTheFirstFlag() {
        let v = ConfigValues(raw: ["glossary": [
            ["term": "Kafka", "transcript": false] as [String: Any],
            ["term": "kafka", "variants": ["cafca"]] as [String: Any],
        ]])
        #expect(v.glossary == [GlossaryEntry(term: "Kafka", variants: ["cafca"], transcript: false)])
    }

    @Test func jsonValueWritesTheFlagOnlyWhenOff() throws {
        #expect(GlossaryEntry(term: "K").jsonValue as? String == "K")
        let off = try #require(GlossaryEntry(term: "K", transcript: false).jsonValue as? [String: Any])
        #expect(off["term"] as? String == "K")
        #expect(off["transcript"] as? Bool == false)
        #expect(off.count == 2)
        let both = try #require(
            GlossaryEntry(term: "D", variants: ["miting vox"], transcript: false).jsonValue as? [String: Any]
        )
        #expect(both["variants"] as? [String] == ["miting vox"])
        #expect(both["transcript"] as? Bool == false)
        #expect(both.count == 3)
        let on = try #require(GlossaryEntry(term: "D", variants: ["miting vox"]).jsonValue as? [String: Any])
        #expect(on["transcript"] == nil)
    }

    @Test func flagRoundTripsThroughConfigStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-glossary-flag-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let entries = [
            GlossaryEntry(term: "Kubernetes"),
            GlossaryEntry(term: "Kafka", variants: ["kafca"], transcript: false),
        ]
        try ConfigStore.set(entries.map(\.jsonValue), at: "glossary", url: url)
        #expect(ConfigValues(raw: try ConfigStore.loadRaw(at: url)).glossary == entries)
    }

    // MARK: Write format

    @Test func jsonValueIsAStringWithoutVariants() {
        #expect(GlossaryEntry(term: "Kubernetes").jsonValue as? String == "Kubernetes")
    }

    @Test func jsonValueIsAnObjectWithVariants() throws {
        let value = GlossaryEntry(term: "MeetingVox", variants: ["miting vox"]).jsonValue
        let object = try #require(value as? [String: Any])
        #expect(object["term"] as? String == "MeetingVox")
        #expect(object["variants"] as? [String] == ["miting vox"])
        #expect(object.count == 2)
    }

    @Test func roundTripThroughConfigStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-glossary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let entries = [
            GlossaryEntry(term: "Kubernetes"),
            GlossaryEntry(term: "MeetingVox", variants: ["miting vox", "mitin vox"]),
        ]
        try ConfigStore.set(entries.map(\.jsonValue), at: "glossary", url: url)
        #expect(ConfigValues(raw: try ConfigStore.loadRaw(at: url)).glossary == entries)
    }

    // MARK: Variants text field

    @Test func variantsFromCommaSeparatedText() {
        #expect(GlossaryEntry.variants(from: " miting vox, mitin vox ,, Miting Vox ,") == ["miting vox", "mitin vox"])
        #expect(GlossaryEntry.variants(from: "   ") == [])
    }

    @Test func variantsTextJoinsWithComma() {
        #expect(GlossaryEntry(term: "D", variants: ["a", "b"]).variantsText == "a, b")
    }

    // MARK: Prompt rendering

    @Test func promptWithoutVariantsListsTerms() {
        let text = MinutesPrompts.glosario([GlossaryEntry(term: "Grafana"), GlossaryEntry(term: "Kubernetes")])
        #expect(text == "Términos propios (escritura correcta); úsalos para corregir errores de transcripción: Grafana, Kubernetes.")
    }

    @Test func promptWithVariantsGivesExplicitHintsAndCaution() {
        let text = MinutesPrompts.glosario([
            GlossaryEntry(term: "MeetingVox", variants: ["miting vox", "mitin vox"]),
            GlossaryEntry(term: "Kafka", variants: ["cafca", "kafca"]),
            GlossaryEntry(term: "Kubernetes"),
        ])
        #expect(text.contains("MeetingVox (puede aparecer como «miting vox», «mitin vox»); Kafka (puede aparecer como «cafca», «kafca»); Kubernetes."))
        #expect(text.hasPrefix("Términos propios (escritura correcta)."))
        #expect(text.contains("solo cuando el contexto"))
    }

    @Test func emptyGlossaryRendersNothing() {
        #expect(MinutesPrompts.glosarioBloque([]) == nil)
        #expect(MinutesPrompts.glosarioBloque([GlossaryEntry(term: "X")]) != nil)
    }

    @Test func summarySystemPromptIncludesGlossary() {
        let prompt = SummaryPrompts.systemPrompt(glossary: [GlossaryEntry(term: "Kafka", variants: ["cafca"])])
        #expect(prompt.contains("Kafka (puede aparecer como «cafca»)"))
        #expect(!SummaryPrompts.systemPrompt(glossary: []).contains("Términos propios"))
    }

    @Test func partialAndReductionPromptsCarryVariants() {
        let glossary = [GlossaryEntry(term: "MeetingVox", variants: ["miting vox"])]
        let partial = PromptBuilder.partialSystemPrompt(part: 1, of: 2, lines: [], language: "español", glossary: glossary)
        let reduction = PromptBuilder.reductionSystemPrompt(from: 1, to: 2, of: 3, language: "español", glossary: glossary)
        #expect(partial.contains("MeetingVox (puede aparecer como «miting vox»)"))
        #expect(reduction.contains("MeetingVox (puede aparecer como «miting vox»)"))
    }
}
