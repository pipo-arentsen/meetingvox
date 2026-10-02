import Foundation

/// What the Minuta tab shows (DT-2). It is `MinutesRequestRoute` — the one
/// reading of the markers the notices and the old Reuniones button shared —
/// plus the live overlay, so a session owed its automatic minutes is offered
/// "Reintentar" and never a competing "Generar minuta". Pure.
enum MinutaTabState: Equatable, Sendable {
    /// `minuta.md`, rendered. `regenerating`: a job is rewriting it now.
    case document(regenerating: Bool)
    /// A minutes job is running (or waiting for its next attempt).
    case running(waitingRetry: Bool)
    /// The automatic request is still owed: it failed for good, or its
    /// retries ran out. Offers "Reintentar".
    case retry(failed: Bool, unavailableReason: String?)
    /// A transcript and nothing owed: template picker and "Generar minuta".
    case generate(unavailableReason: String?)
    /// No minutes and nothing to make them from.
    case noTranscript

    /// - Parameter unavailableReason: why minutes cannot run now (no key, no
    ///   model); nil when they can.
    static func derive(
        hasMinutes: Bool, minutesPending: Bool, minutesFailed: Bool, hasTranscript: Bool,
        live: LiveStages, unavailableReason: String?
    ) -> MinutaTabState {
        let liveMinutes = live[.minutes]
        switch MinutesRequestRoute.decide(
            hasMinutes: hasMinutes, hasPendingOrFailedRequest: minutesPending || minutesFailed, hasTranscript: hasTranscript
        ) {
        case .openMinutes:
            return .document(regenerating: liveMinutes != nil)
        case .retryAutomatic:
            if let liveMinutes { return .running(waitingRetry: liveMinutes == .waitingRetry) }
            return .retry(failed: minutesFailed && !minutesPending, unavailableReason: unavailableReason)
        case .generate:
            if let liveMinutes { return .running(waitingRetry: liveMinutes == .waitingRetry) }
            return .generate(unavailableReason: unavailableReason)
        case .unavailable:
            return liveMinutes.map { .running(waitingRetry: $0 == .waitingRetry) } ?? .noTranscript
        }
    }

    static func derive(entry: MeetingEntry, live: LiveStages, unavailableReason: String?) -> MinutaTabState {
        derive(
            hasMinutes: entry.hasMinutes, minutesPending: entry.minutesPending, minutesFailed: entry.minutesFailed,
            hasTranscript: entry.hasTranscript, live: live, unavailableReason: unavailableReason
        )
    }

    /// Where the template picker starts: the session's own earlier choice
    /// (meta.json), else the configured template, else the first one; nil
    /// with no templates.
    static func initialTemplate(_ templates: [MinutesTemplate], sessionChoice: String?, configured: String?) -> String? {
        let ids = Set(templates.map(\.id))
        if let sessionChoice, ids.contains(sessionChoice) { return sessionChoice }
        if let configured, ids.contains(configured) { return configured }
        return templates.first?.id
    }
}
