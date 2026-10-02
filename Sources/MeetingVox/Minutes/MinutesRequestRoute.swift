import Foundation

/// What a request for a session's minutes calls for, given what is on disk.
/// The one rule behind both the Minuta tab (via `MinutaTabState`) and the
/// notification's "Reintentar"; each caller maps the cases it needs its own
/// way (the tab renders the document, the notice shows the session).
enum MinutesRequestRoute: Equatable {
    /// `minuta.md` exists.
    case openMinutes
    /// `minuta.pendiente`/`minuta.error` on disk: the automatic request is
    /// still owed, so it goes back through `MinutesCoordinator.retry`.
    case retryAutomatic
    /// A transcript and nothing owed: a pure user-requested job
    /// (`MinutesCoordinator.generateFromWindow`), which leaves no marker.
    case generate
    /// No minutes, nothing owed, no transcript to work from.
    case unavailable

    static func decide(hasMinutes: Bool, hasPendingOrFailedRequest: Bool, hasTranscript: Bool) -> MinutesRequestRoute {
        if hasMinutes { return .openMinutes }
        if hasPendingOrFailedRequest { return .retryAutomatic }
        return hasTranscript ? .generate : .unavailable
    }

    /// From a scanned session, as the main window sees it.
    static func decide(_ entry: MeetingEntry) -> MinutesRequestRoute {
        decide(
            hasMinutes: entry.hasMinutes, hasPendingOrFailedRequest: entry.minutesPending || entry.minutesFailed,
            hasTranscript: entry.hasTranscript
        )
    }

    /// From the markers on disk, as a tapped notice sees it.
    static func decide(dir: URL) -> MinutesRequestRoute {
        let has = { SessionFiles.exists($0, in: dir) }
        return decide(
            hasMinutes: has(SessionFiles.minutes),
            hasPendingOrFailedRequest: has(SessionFiles.minutesPending) || has(SessionFiles.minutesError),
            hasTranscript: has(SessionFiles.transcriptJSON)
        )
    }
}
