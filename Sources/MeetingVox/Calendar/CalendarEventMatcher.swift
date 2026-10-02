import Foundation

/// Picks the calendar event a recording most likely belongs to. Pure and
/// deterministic: every input order gives the same answer.
enum CalendarEventMatcher {
    /// Events that began up to this long before the recording still count
    /// (people join a call from the reminder, a few minutes early).
    static let lookBack: TimeInterval = 10 * 60

    /// The range an event may overlap to count: from `lookBack` before the
    /// recording starts to when it ends.
    static func window(for recording: DateInterval) -> DateInterval {
        DateInterval(start: recording.start.addingTimeInterval(-lookBack), end: recording.end)
    }

    /// Whether an event spanning `start..end` overlaps that window.
    static func overlapsWindow(start: Date, end: Date, recording: DateInterval) -> Bool {
        let window = window(for: recording)
        return start < window.end && end > window.start
    }

    /// Candidates: timed, with a non-blank title, not cancelled, not declined
    /// by the user, involving the user (organizer or attendee, or nobody else
    /// is invited: events of shared or subscribed calendars they are not part
    /// of are never linked) and overlapping `[recording.start - 10 min,
    /// recording.end]`. Ranking, first difference wins: (1) a video link of
    /// the service matching `meetingApp`; (2) any video link; (3) longest
    /// overlap with the recording; (4) start closest to the recording's; (5)
    /// id ascending.
    static func pick(
        from events: [CalendarEventSnapshot], recording: DateInterval, meetingApp: String?
    ) -> CalendarEventSnapshot? {
        return events
            .filter { isCandidate($0, recording: recording) }
            .min { better($0, than: $1, recording: recording, meetingApp: meetingApp) }
    }

    private static func isCandidate(_ event: CalendarEventSnapshot, recording: DateInterval) -> Bool {
        !event.isAllDay && !event.isCancelled && event.selfStatus != .declined
            && !CalendarText.title(event.title).isEmpty && involvesMe(event)
            && overlapsWindow(start: event.start, end: event.end, recording: recording)
    }

    private static func involvesMe(_ event: CalendarEventSnapshot) -> Bool {
        event.organizer?.isSelf == true || event.attendees.contains { $0.isSelf } || event.attendees.isEmpty
    }

    private static func overlap(_ event: CalendarEventSnapshot, _ recording: DateInterval) -> TimeInterval {
        max(0, min(event.end, recording.end).timeIntervalSince(max(event.start, recording.start)))
    }

    private static func better(
        _ a: CalendarEventSnapshot, than b: CalendarEventSnapshot, recording: DateInterval, meetingApp: String?
    ) -> Bool {
        func hostMatches(_ e: CalendarEventSnapshot) -> Bool {
            e.videoURLs.contains { CalendarVideoLink.service(for: $0)?.matches(meetingApp: meetingApp) == true }
        }
        func hasVideo(_ e: CalendarEventSnapshot) -> Bool {
            e.videoURLs.contains { CalendarVideoLink.service(for: $0) != nil }
        }
        let flags: [(Bool, Bool)] = [(hostMatches(a), hostMatches(b)), (hasVideo(a), hasVideo(b))]
        for (left, right) in flags where left != right { return left }
        let overlapA = overlap(a, recording), overlapB = overlap(b, recording)
        if overlapA != overlapB { return overlapA > overlapB }
        let gapA = abs(a.start.timeIntervalSince(recording.start)), gapB = abs(b.start.timeIntervalSince(recording.start))
        if gapA != gapB { return gapA < gapB }
        return a.id < b.id
    }
}
