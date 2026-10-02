import Foundation
import SwiftUI
import Testing
@testable import MeetingVox

@Suite struct MarkdownInlineTests {
    private func plain(_ a: AttributedString) -> String { String(a.characters) }

    private func intents(_ a: AttributedString) -> [InlinePresentationIntent] {
        a.runs.compactMap { $0.inlinePresentationIntent }
    }

    @Test func plainTextComesBackUnchanged() {
        #expect(plain(MarkdownInline.attributed("Reunión con Participante 1, 12 de octubre.")) == "Reunión con Participante 1, 12 de octubre.")
    }

    @Test func boldItalicAndCodeBecomeStyledRunsWithoutTheMarkers() {
        let attributed = MarkdownInline.attributed("**negrita**, *cursiva* y `código`")

        #expect(plain(attributed) == "negrita, cursiva y código")
        #expect(intents(attributed).contains(.stronglyEmphasized))
        #expect(intents(attributed).contains(.emphasized))
        #expect(intents(attributed).contains(.code))
    }

    @Test func linksKeepTheirLabelAndTarget() {
        let attributed = MarkdownInline.attributed("ver [la propuesta](https://example.com/p)")

        #expect(plain(attributed) == "ver la propuesta")
        #expect(attributed.runs.compactMap(\.link) == [URL(string: "https://example.com/p")!])
    }

    @Test func lineBreaksAreKept() {
        #expect(plain(MarkdownInline.attributed("uno\ndos")) == "uno\ndos")
    }

    @Test func anEscapedPipeAndUnmatchedMarkersDegradeToReadableText() {
        #expect(plain(MarkdownInline.attributed("a\\|b")) == "a|b")
        // An unmatched marker never throws and never eats the words around it.
        let unmatched = plain(MarkdownInline.attributed("**sin cerrar y más texto"))
        #expect(unmatched.contains("sin cerrar y más texto"))
    }

    @Test func headingsAndBlockSyntaxAreNotInterpretedInline() {
        // Block syntax is the parser's job; inline-only must leave it as text.
        #expect(plain(MarkdownInline.attributed("# no es título")).contains("no es título"))
    }

    @Test func emptyStringIsEmpty() {
        #expect(plain(MarkdownInline.attributed("")) == "")
    }

    @Test func plainFallbackKeepsTheText() {
        #expect(plain(MarkdownInline.plain("**crudo**")) == "**crudo**")
    }

    // MARK: - Link policy

    private func links(_ markdown: String) -> [URL] { MarkdownInline.attributed(markdown).runs.compactMap(\.link) }

    @Test func httpHttpsAndMailtoLinksAreKeptCaseInsensitively() {
        #expect(links("[a](http://example.com)") == [URL(string: "http://example.com")!])
        #expect(links("[a](https://example.com/x)") == [URL(string: "https://example.com/x")!])
        #expect(links("[a](mailto:ana@example.com)") == [URL(string: "mailto:ana@example.com")!])
        #expect(links("[a](HTTPS://example.com)").count == 1)
    }

    @Test func otherSchemesRenderAsPlainTextKeepingTheLabel() {
        let cases = [
            "[Abrir](file:///Applications/X.app)", "[shell](ssh://host/path)",
            "[ajustes](x-apple.systempreferences:com.apple.preference.security)", "[clic](javascript:alert(1))",
            "[app](myapp://open?x=1)", "[rel](carpeta/archivo.md)",
        ]
        for markdown in cases {
            let attributed = MarkdownInline.attributed(markdown)
            #expect(attributed.runs.compactMap(\.link).isEmpty, "\(markdown) kept a link")
            #expect(!plain(attributed).isEmpty && !plain(attributed).contains("]("), "\(markdown) lost its label")
        }
        #expect(plain(MarkdownInline.attributed("[Abrir](file:///Applications/X.app)")) == "Abrir")
    }

    @Test func aDroppedLinkDoesNotAffectItsNeighbours() {
        let attributed = MarkdownInline.attributed("[ok](https://a.example) y [mal](file:///etc/hosts) fin")

        #expect(plain(attributed) == "ok y mal fin")
        #expect(attributed.runs.compactMap(\.link) == [URL(string: "https://a.example")!])
    }

    @Test func isAllowedLinkGuardsTheOpenURLAction() {
        #expect(MarkdownInline.isAllowedLink(URL(string: "https://example.com")!))
        #expect(MarkdownInline.isAllowedLink(URL(string: "mailto:a@b.co")!))
        #expect(!MarkdownInline.isAllowedLink(URL(string: "file:///Applications/X.app")!))
        #expect(!MarkdownInline.isAllowedLink(URL(string: "ssh://host")!))
        #expect(!MarkdownInline.isAllowedLink(URL(string: "javascript:alert(1)")!))
        #expect(!MarkdownInline.isAllowedLink(URL(string: "x-apple.systempreferences:a")!))
        #expect(!MarkdownInline.isAllowedLink(URL(string: "relative/path")!))
    }
}
