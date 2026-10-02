import Testing

@testable import MeetingVox

/// The main window's column constants must fit together: they are the only
/// place the widths live, so a bad edit shows here rather than as a clipped
/// column.
@Suite("MainLayout")
struct MainLayoutTests {
    @Test func eachColumnsIdealWidthLiesInsideItsRange() {
        #expect(MainLayout.sidebarRange.contains(MainLayout.sidebarWidth))
        #expect(MainLayout.listRange.contains(MainLayout.listWidth))
        #expect(MainLayout.sidebarWidth == 220)
        #expect(MainLayout.listWidth == 330)
    }

    @Test func theDefaultWindowFitsAllThreeColumnsAtTheirIdealWidth() {
        let needed = MainLayout.sidebarWidth + MainLayout.listWidth + MainLayout.detailMinimumWidth
        #expect(MainLayout.defaultSize.width >= needed)
        #expect(MainLayout.defaultSize.width == 1280)
        #expect(MainLayout.defaultSize.height == 820)
    }

    @Test func theSmallestWindowStillFitsTheColumnsAtTheirMinimums() {
        let needed = MainLayout.sidebarRange.lowerBound + MainLayout.listRange.lowerBound + MainLayout.detailMinimumWidth
        #expect(MainLayout.minimumSize.width >= needed)
        #expect(MainLayout.minimumSize.width <= MainLayout.defaultSize.width)
        #expect(MainLayout.minimumSize.height <= MainLayout.defaultSize.height)
    }
}
