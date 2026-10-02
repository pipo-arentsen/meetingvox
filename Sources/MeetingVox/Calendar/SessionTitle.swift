import Foundation

/// The one rule for a session's display title: the calendar event's title,
/// else the summary's, else the row header, else the folder name. Pure; each
/// candidate is trimmed and blank ones are skipped. `resumen.json` is never
/// modified: this only decides what is shown.
enum SessionTitle {
    static func resolve(calendar: String?, summary: String?, header: String?, folder: String? = nil) -> String? {
        for candidate in [calendar, summary, header, folder] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
