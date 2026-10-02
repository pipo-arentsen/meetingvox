import Foundation
import Testing
@testable import MeetingVox

@Suite struct DetailModeTests {
    @Test func noVisibleSelectionShowsNothing() {
        #expect(DetailMode.of(selectedVisible: 0) == .none)
    }

    @Test func oneVisibleRowShowsTheSessionDetail() {
        #expect(DetailMode.of(selectedVisible: 1) == .single)
    }

    @Test func twoOrMoreShowTheBulkPanelWithTheCount() {
        #expect(DetailMode.of(selectedVisible: 2) == .bulk(2))
        #expect(DetailMode.of(selectedVisible: 5) == .bulk(5))
    }

    @Test func bulkTitleUsesTheSpanishCount() {
        #expect(DetailMode.bulk(3).bulkTitle == "3 seleccionadas")
        #expect(DetailMode.single.bulkTitle == nil)
        #expect(DetailMode.none.bulkTitle == nil)
    }

    @Test func aNegativeCountIsTreatedAsNone() {
        #expect(DetailMode.of(selectedVisible: -1) == .none)
    }
}
