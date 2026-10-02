import SwiftUI
import Testing

@testable import MeetingVox

/// VS-3: pure-SwiftUI subviews (no List / SplitView) do render under
/// `swift test` through `ImageRenderer`, so later units can assert on them
/// without the AppKit harness. The subject is `MarkdownDocumentView`, the one
/// view with real content this unit ships. Not a bare "it rendered": the
/// image is measured (it is as wide as the reading column allows and as tall
/// as its content) and checked for ink.
@MainActor
@Suite("ImageRendererSmoke")
struct ImageRendererSmokeTests {
    private func render(_ text: String) throws -> CGImage {
        let view = MarkdownDocumentView(text: text)
            .padding(16)
            .frame(width: 720, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    @Test func aMinutesDocumentRendersWithInkAndItsOwnHeight() throws {
        let image = try render(SnapshotFixtures.sampleMinutes)

        #expect(image.width == 720)
        #expect(image.height > 400) // title, sections, list items and a table
        #expect(!SnapshotBlankCheck.isBlank(image))
    }

    @Test func aLongerDocumentIsTallerThanAShortOne() throws {
        let short = try render("# Título\n\nUn párrafo breve.")
        let long = try render(SnapshotFixtures.sampleMinutes)

        #expect(short.height < long.height)
        #expect(!SnapshotBlankCheck.isBlank(short)) // triangulation: a tiny document has ink too
    }

    @Test func aTableAddsHeightOverTheSameTextWithoutIt() throws {
        let withTable = try render("# T\n\n| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n")
        let without = try render("# T\n")

        #expect(withTable.height > without.height)
    }

    @Test func aBlankImageIsRecognizedAsBlank() throws {
        // Control for the ink assertions above: a view that draws nothing.
        let renderer = ImageRenderer(content: Color.white.frame(width: 200, height: 100))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)

        #expect(SnapshotBlankCheck.isBlank(image))
    }
}
