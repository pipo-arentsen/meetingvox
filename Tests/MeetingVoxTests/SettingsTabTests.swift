import Testing
@testable import MeetingVox

/// Ajustes no longer offers a Glosario tab (it lives in
/// the main window's Biblioteca). The tab list is data so this is assertable.
@Suite struct SettingsTabTests {
    @Test func settingsHasExactlyTheThreeExpectedTabsInOrder() {
        #expect(SettingsTab.allCases.map(\.title) == ["OpenRouter", "Reuniones", "Memoria"])
    }

    @Test func settingsHasNoGlosarioTab() {
        let titles = SettingsTab.allCases.map { $0.title.lowercased() }
        #expect(!titles.contains { $0.contains("glosario") })
        #expect(SettingsTab.allCases.count == 3)
    }
}
