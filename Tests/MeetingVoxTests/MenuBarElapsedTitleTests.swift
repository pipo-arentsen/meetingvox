import AppKit
import Testing
@testable import MeetingVox

/// While recording the status item shows the elapsed time next to the
/// feather, in monospaced digits so the item never jitters as it ticks.
@MainActor
@Suite struct MenuBarElapsedTitleTests {
    @Test func theTitleIsTheElapsedTimeAfterAGap() {
        #expect(MenuBarController.elapsedTitle("1:05")?.string == " 1:05")
        #expect(MenuBarController.elapsedTitle("1:02:09")?.string == " 1:02:09")
    }

    @Test func notRecordingMeansNoTitle() {
        #expect(MenuBarController.elapsedTitle(nil) == nil)
    }

    @Test func digitsAreMonospacedSoTheWidthNeverChanges() throws {
        let narrow = try #require(MenuBarController.elapsedTitle("1:11"))
        let wide = try #require(MenuBarController.elapsedTitle("0:08"))
        #expect(narrow.size().width == wide.size().width)
        // Non-vacuous: the same strings in the proportional system font differ,
        // so equal widths above come from the monospaced digits, not from the test.
        let proportional = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let a = NSAttributedString(string: " 1:11", attributes: [.font: proportional]).size().width
        let b = NSAttributedString(string: " 0:08", attributes: [.font: proportional]).size().width
        #expect(a != b)
    }
}
