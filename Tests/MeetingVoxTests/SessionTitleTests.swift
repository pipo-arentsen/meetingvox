import Foundation
import Testing

@testable import MeetingVox

/// Calendar title > summary title > row header > folder name.
@Suite struct SessionTitleTests {
    @Test func theCalendarTitleWinsOverTheSummary() {
        #expect(SessionTitle.resolve(calendar: "Weekly X", summary: "Y", header: "Mié 30 sep") == "Weekly X")
    }

    @Test func aBlankCalendarTitleFallsThroughToTheSummary() {
        #expect(SessionTitle.resolve(calendar: "   ", summary: "Y", header: "H") == "Y")
        #expect(SessionTitle.resolve(calendar: nil, summary: "Y", header: "H") == "Y")
        #expect(SessionTitle.resolve(calendar: "", summary: "  Y  ", header: "H") == "Y")
    }

    @Test func theHeaderThenTheFolderComeLast() {
        #expect(SessionTitle.resolve(calendar: nil, summary: nil, header: "Mié 30 sep · 10:00") == "Mié 30 sep · 10:00")
        #expect(SessionTitle.resolve(calendar: nil, summary: " ", header: nil, folder: "2026.09.30-1000") == "2026.09.30-1000")
        #expect(SessionTitle.resolve(calendar: nil, summary: nil, header: "  ", folder: "f") == "f")
    }

    @Test func nothingAtAllIsNil() {
        #expect(SessionTitle.resolve(calendar: nil, summary: nil, header: nil) == nil)
        #expect(SessionTitle.resolve(calendar: " ", summary: " ", header: " ", folder: " ") == nil)
    }

    @Test func theCalendarTitleIsTrimmed() {
        #expect(SessionTitle.resolve(calendar: "  Weekly X \n", summary: nil, header: nil) == "Weekly X")
    }
}
