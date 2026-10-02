import Foundation
@testable import MeetingVox

/// A `MeetingEntry` built in memory (no disk) for the pure main-window
/// derivations: pill, stepper, counts, sections.
func makeEntry(
    _ name: String = "2026.09.29-1000",
    started: Date? = Date(timeIntervalSince1970: 1_790_000_000),
    hasTranscript: Bool = true,
    hasMinutes: Bool = false,
    minutesPending: Bool = false,
    minutesFailed: Bool = false,
    summaryState: SessionSettlement.MarkerState = .absent,
    ambito: Ambito? = nil
) -> MeetingEntry {
    MeetingEntry(
        dir: URL(fileURLWithPath: "/fake/root/\(name)"), started: started, durationSeconds: nil, app: nil,
        summary: nil, hasMinutes: hasMinutes, hasTranscript: hasTranscript,
        minutesPending: minutesPending, minutesFailed: minutesFailed, ambito: ambito,
        summaryState: summaryState
    )
}
