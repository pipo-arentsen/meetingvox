import AppKit
import SwiftUI

/// A plain-text editor for raw markdown: an `NSTextView` in a scroll view,
/// monospaced, with every "helpful" substitution off. SwiftUI's `TextEditor`
/// leaves smart quotes and dashes on, which would turn `"` into curly quotes
/// and `--` into a dash inside a prompt or its frontmatter, silently.
///
/// The configuration lives in static functions (`makeTextView`, `sync`,
/// `setEditable`) so the tests check the flags on the created view without a
/// window.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true

    static let fontSize: CGFloat = 12

    /// A text view that types exactly what it is given.
    @MainActor
    static func makeTextView() -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .textColor
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        return textView
    }

    /// Replace the view's text only when it differs, so typing (which already
    /// wrote the binding) never resets the caret.
    @MainActor
    static func sync(_ textView: NSTextView, to text: String) {
        guard textView.string != text else { return }
        textView.string = text
    }

    @MainActor
    static func setEditable(_ textView: NSTextView, _ editable: Bool) {
        textView.isEditable = editable
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = Self.makeTextView()
        textView.delegate = context.coordinator
        textView.string = text
        Self.setEditable(textView, isEditable)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        Self.sync(textView, to: text)
        Self.setEditable(textView, isEditable)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
