import Foundation
import Testing
@testable import MeetingVox

/// What the Resumen tab shows when `resumen.json` is (or is not) there (DT-1).
@Suite struct ResumenTabStateTests {
    private let summary = MeetingSummary(
        title: "Plan", summary: "Se acordó.", client: nil, topics: ["A"], participants: ["Participante 1"],
        source: .transcript, model: "m", generatedAt: Date(timeIntervalSince1970: 0)
    )

    @Test func aSummaryOnDiskIsShown() {
        var entry = makeEntry(summaryState: .done)
        entry = MeetingEntry(
            dir: entry.dir, started: entry.started, durationSeconds: nil, app: nil, summary: summary,
            hasMinutes: false, hasTranscript: true, summaryState: .done
        )
        #expect(ResumenTabState.derive(entry: entry, live: [:], summaryApplies: true) == .summary(summary))
    }

    @Test func aPendingOrRunningSummaryIsBeingWrittenNow() {
        #expect(ResumenTabState.derive(entry: makeEntry(summaryState: .pending), live: [:], summaryApplies: true) == .generating)
        #expect(ResumenTabState.derive(entry: makeEntry(), live: [.summary: .running], summaryApplies: true) == .generating)
        #expect(ResumenTabState.derive(entry: makeEntry(), live: [.summary: .waitingRetry], summaryApplies: true) == .generating)
    }

    @Test func aFailedSummaryPointsAtTheStepperRetry() {
        #expect(ResumenTabState.derive(entry: makeEntry(summaryState: .failed), live: [:], summaryApplies: true) == .failed)
    }

    @Test func noSummaryYetWithSummariesOnIsWaiting() {
        #expect(ResumenTabState.derive(entry: makeEntry(), live: [:], summaryApplies: true) == .none(applies: true))
        #expect(ResumenTabState.derive(entry: makeEntry(hasTranscript: false), live: [:], summaryApplies: true) == .none(applies: true))
    }

    @Test func noSummaryWithSummariesOffSaysItIsNotGenerated() {
        #expect(ResumenTabState.derive(entry: makeEntry(), live: [:], summaryApplies: false) == .none(applies: false))
    }

    @Test func aMalformedSummaryFileWithTheMarkerDoneIsNotShownAsGenerating() {
        // resumen.json exists but does not decode: `summary` is nil while the marker says done.
        #expect(ResumenTabState.derive(entry: makeEntry(summaryState: .done), live: [:], summaryApplies: true) == .none(applies: true))
    }
}
