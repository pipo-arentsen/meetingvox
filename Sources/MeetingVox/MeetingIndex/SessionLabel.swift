import Foundation

/// The one-line name of a session in the status menu: the calendar event's
/// title when linked, else the summary title when there is one, else the
/// detail header (`Jue 24 sep · 10:53–11:05 (12 min)`), else the folder name
/// — cut to `maxLength` with an ellipsis so a long title never widens the
/// menu. Pure (`text`); `load` only reads.
enum SessionLabel {
    static let maxLength = 48

    static func text(
        summaryTitle: String?, calendarTitle: String? = nil, started: Date?, ended: Date?, durationSeconds: Int?,
        folder: String, timeZone: TimeZone, maxLength: Int = SessionLabel.maxLength
    ) -> String {
        let full = SessionTitle.resolve(
            calendar: calendarTitle, summary: summaryTitle,
            header: MeetingRowHeader.text(started: started, ended: ended, durationSeconds: durationSeconds, timeZone: timeZone),
            folder: folder)
        return truncated(full ?? folder, to: maxLength)
    }

    /// Reads the session folder through `MeetingEntry`, so the menu and the
    /// main window agree on the title and the date (including the
    /// folder-name date when `meta.json` is missing).
    static func load(_ dir: URL, timeZone: TimeZone = .current) -> String {
        let entry = MeetingEntry.load(dir)
        return text(
            summaryTitle: entry.summary?.title, calendarTitle: entry.calendarEvent?.title, started: entry.started, ended: entry.ended,
            durationSeconds: entry.durationSeconds, folder: dir.lastPathComponent, timeZone: timeZone
        )
    }

    private static func truncated(_ text: String, to maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let head = text.prefix(max(maxLength - 1, 0)).trimmingCharacters(in: .whitespaces)
        return head + "…"
    }
}
