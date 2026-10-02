import Foundation
import Testing
@testable import MeetingVox

/// The AND-over-the-union match and the snippet rule.
@Suite struct SearchMatcherTests {
    private func line(_ id: Int, _ text: String) -> TranscriptViewLine {
        TranscriptViewLine(id: id, startMs: id * 1000, speaker: "me", text: text)
    }

    private func doc(_ lines: [String] = [], minutes: String? = nil) -> FullTextDocument {
        FullTextDocument.make(transcript: lines.enumerated().map { line($0.offset, $0.element) }, minutes: minutes)
    }

    private func match(_ query: String, metadata: String = "", _ document: FullTextDocument) -> SearchMatcher.Outcome {
        SearchMatcher.match(tokens: SearchMatcher.tokens(of: query), metadata: metadata, document: document)
    }

    private func hit(_ o: SearchMatcher.Outcome) -> SearchHit? {
        if case .hit(let h) = o { return h } else { return nil }
    }

    private func highlighted(_ h: SearchHit) -> [String] {
        h.snippet.highlights.map { (h.snippet.text as NSString).substring(with: $0) }
    }

    // MARK: - Union and AND

    @Test func aTranscriptOnlyPhraseMatchesFoldedAndShowsASnippet() {
        let outcome = match("cotizacion FINAL", doc(["hola", "la cotización final está lista"]))
        let h = hit(outcome)
        #expect(h?.source == .transcript)
        #expect(h?.lineID == 1)
        #expect(h.map(highlighted) == ["cotización", "final"])
    }

    @Test func tokensSplitAcrossMetadataAndTranscriptStillMatch() {
        let outcome = match("proveedor cotizacion", metadata: "Kickoff Proveedor", doc(["hablamos de la cotización"]))
        let h = hit(outcome)
        #expect(h?.lineID == 0)
        #expect(h.map(highlighted) == ["cotización"], "the snippet shows what the metadata could not")
    }

    @Test func aTokenInNoSourceHidesTheSession() {
        #expect(match("cotizacion zzz", metadata: "x", doc(["cotización"], minutes: "# Acta")) == .none)
    }

    @Test func metadataAloneIsAMetadataMatchWithNoSnippet() {
        #expect(match("proveedor", metadata: "Kickoff Proveedor", doc(["proveedor también"])) == .metadata)
    }

    @Test func minutesOnlyTextIsAMinutesHit() {
        let outcome = match("presupuesto", doc(["hola"], minutes: "# Acta\n\n- Se aprobó el presupuesto anual"))
        let h = hit(outcome)
        #expect(h?.source == .minutes)
        #expect(h.map(highlighted) == ["presupuesto"])
        #expect(h?.snippet.text.contains("- ") == false, "markdown list markers are not in the snippet")
    }

    @Test func aTokenSplitAcrossTranscriptAndMinutesMatches() {
        #expect(hit(match("acuerdo plazo", doc(["el acuerdo"], minutes: "- plazo de 3 meses"))) != nil)
    }

    // MARK: - Snippet rule (rev 2)

    @Test func theSnippetComesFromTheLineWithAllTokensNotTheFirstPartialOne() {
        let lines = ["hola", "la cotización", "x", "y", "z", "w", "más cotización final aquí"]
        let h = hit(match("cotizacion final", doc(lines)))
        #expect(h?.lineID == 6)
    }

    @Test func aTranscriptLineWithAllTokensBeatsAMinutesLineWithAllTokens() {
        let h = hit(match("costo total", doc(["costo total 500"], minutes: "- costo total acordado")))
        #expect(h?.source == .transcript)
    }

    @Test func aMinutesLineWithAllTokensBeatsAPartialTranscriptLine() {
        let h = hit(match("costo total", doc(["el costo solo"], minutes: "- costo total acordado")))
        #expect(h?.source == .minutes)
    }

    @Test func withNoLineHoldingAllTokensTheFirstMatchingLineWins() {
        let h = hit(match("alfa beta", doc(["nada", "solo alfa", "solo beta"])))
        #expect(h?.lineID == 1)
    }

    // MARK: - Snippet bounds

    @Test func aShortLineIsTheWholeSnippet() {
        let h = hit(match("final", doc(["La cotización final"])))
        #expect(h?.snippet.text == "La cotización final")
    }

    @Test func aLongLineIsCutAroundTheMatchToAboutOneHundredTwentyCharacters() throws {
        let filler = String(repeating: "palabra ", count: 40)
        let text = filler + "la cotización final llegó " + filler
        let h = try #require(hit(match("cotizacion", doc([text]))))
        let len = (h.snippet.text as NSString).length
        #expect(len <= 122, "120 plus at most two ellipses")
        #expect(len >= 100)
        #expect(h.snippet.text.hasPrefix("…") && h.snippet.text.hasSuffix("…"))
        #expect(highlighted(h) == ["cotización"])
    }

    @Test func aMatchAtTheStartKeepsNoLeadingEllipsis() throws {
        let text = "cotización " + String(repeating: "relleno ", count: 60)
        let h = try #require(hit(match("cotizacion", doc([text]))))
        #expect(!h.snippet.text.hasPrefix("…"))
        #expect(h.snippet.text.hasSuffix("…"))
        #expect(h.snippet.highlights.first?.location == 0)
    }

    @Test func aMatchAtTheEndKeepsNoTrailingEllipsis() throws {
        let text = String(repeating: "relleno ", count: 60) + "cotización"
        let h = try #require(hit(match("cotizacion", doc([text]))))
        #expect(h.snippet.text.hasPrefix("…"))
        #expect(!h.snippet.text.hasSuffix("…"))
        #expect(highlighted(h) == ["cotización"])
    }

    @Test func tokensOfAQueryAreFoldedAndSplitOnSpaces() {
        #expect(SearchMatcher.tokens(of: "  Cotización   FINAL ") == ["cotizacion", "final"])
        #expect(SearchMatcher.tokens(of: "   ").isEmpty)
    }
}
