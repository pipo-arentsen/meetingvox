import AppKit
import Testing

@testable import MeetingVox

/// The template editor edits raw markdown and YAML-ish frontmatter, so the
/// text view must never "improve" what is typed: no curly quotes, no en/em
/// dashes, no text replacement, no spelling correction, no link or data
/// detection. Checked on the view the representable creates (no window).
@MainActor
@Suite("PlainTextEditor")
struct PlainTextEditorTests {
    @Test func theTextViewSubstitutesNothingWhileTheUserTypes() {
        let textView = PlainTextEditor.makeTextView()

        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isAutomaticDataDetectionEnabled)
        #expect(!textView.isAutomaticLinkDetectionEnabled)
        #expect(!textView.isAutomaticTextCompletionEnabled)
        #expect(!textView.isContinuousSpellCheckingEnabled)
        #expect(!textView.isGrammarCheckingEnabled)
    }

    @Test func itIsPlainMonospacedUndoableText() {
        let textView = PlainTextEditor.makeTextView()

        #expect(!textView.isRichText)
        #expect(!textView.importsGraphics)
        #expect(textView.allowsUndo)
        #expect(textView.isEditable)
        #expect(textView.font?.isFixedPitch == true)
        #expect(textView.isSelectable)
    }

    @Test func settingTheTextThroughTheBridgeReplacesTheViewContentOnlyWhenItDiffers() {
        let textView = PlainTextEditor.makeTextView()

        PlainTextEditor.sync(textView, to: "uno")
        #expect(textView.string == "uno")

        textView.setSelectedRange(NSRange(location: 2, length: 0))
        PlainTextEditor.sync(textView, to: "uno")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0), "same text: the caret stays")

        PlainTextEditor.sync(textView, to: "dos")
        #expect(textView.string == "dos")
    }

    @Test func aReadOnlyEditorCannotBeTyped() {
        let textView = PlainTextEditor.makeTextView()

        PlainTextEditor.setEditable(textView, false)
        #expect(!textView.isEditable)
        PlainTextEditor.setEditable(textView, true)
        #expect(textView.isEditable)
    }
}
