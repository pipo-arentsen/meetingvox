import Testing
@testable import MeetingVox

@Suite("ListEmptyState")
struct ListEmptyStateTests {
    @Test func beforeTheFirstScanNothingIsSaidYet() {
        #expect(ListEmptyState.of(hasLoaded: false, total: 0, shown: 0) == .loading)
    }

    @Test func aScannedRootWithNoSessionsInvitesTheFirstRecording() {
        #expect(ListEmptyState.of(hasLoaded: true, total: 0, shown: 0) == .emptyRoot)
    }

    @Test func sessionsHiddenByTheFiltersSayNoneMatch() {
        #expect(ListEmptyState.of(hasLoaded: true, total: 12, shown: 0) == .noMatches)
    }

    @Test func rowsToShowMeanNoEmptyState() {
        #expect(ListEmptyState.of(hasLoaded: true, total: 12, shown: 3) == nil)
        #expect(ListEmptyState.of(hasLoaded: false, total: 12, shown: 3) == nil, "stale rows still show while a rescan runs")
    }

    @Test func eachStateHasSpanishCopy() {
        #expect(ListEmptyState.emptyRoot.title == Textos.Principal.sinReunionesTitulo)
        #expect(ListEmptyState.noMatches.title == Textos.Indice.sinReuniones)
        #expect(ListEmptyState.loading.title == Textos.Principal.cargando)
    }
}
