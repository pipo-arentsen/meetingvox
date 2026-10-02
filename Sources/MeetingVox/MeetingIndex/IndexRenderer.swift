import Foundation

/// Renders `indice.md` from a flat list of entries: grouped by month
/// (newest first, Spanish names), one entry per session. Pure — the caller
/// (`IndexWriter`) owns the disk I/O, so this is trivial to test with a
/// fixed clock and time zone.
enum IndexRenderer {
    static func render(entries: [MeetingEntry], now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "es_CL")
        monthFormatter.timeZone = timeZone
        monthFormatter.dateFormat = "LLLL yyyy"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "es_CL")
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "HH:mm"

        let sorted = entries.sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }

        var lines = ["# Índice de reuniones", ""]
        var currentMonthKey: DateComponents?
        for entry in sorted {
            let date = entry.started ?? now
            let monthKey = calendar.dateComponents([.year, .month], from: date)
            if monthKey != currentMonthKey {
                currentMonthKey = monthKey
                lines.append("## \(capitalized(monthFormatter.string(from: date)))")
                lines.append("")
            }
            lines.append(contentsOf: render(entry, time: entry.started.map { timeFormatter.string(from: $0) }))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func render(_ entry: MeetingEntry, time: String?) -> [String] {
        let name = entry.dir.lastPathComponent
        var heading = "### \(name)"
        if let time { heading += " · \(time)" }
        var lines = [heading]

        let calendarTitle = entry.calendarEvent.map { escapeMarkdown($0.title) }
        if let summary = entry.summary {
            let shown = SessionTitle.resolve(calendar: calendarTitle, summary: summary.title, header: nil) ?? ""
            var title = "**\(shown)**"
            if let client = summary.client, !client.isEmpty { title += " — \(client)" }
            lines.append(title)
            lines.append("")
            lines.append(summary.summary)
            if !summary.topics.isEmpty {
                lines.append("")
                lines.append("Temas: \(summary.topics.joined(separator: ", "))")
            }
        } else {
            // A linked session is named by its event; the summary line still
            // says there is none.
            if let calendarTitle {
                lines.append("**\(calendarTitle)**")
                lines.append("")
            }
            lines.append("(sin resumen)")
        }

        lines.append("")
        var links = ["[Carpeta](\(name))"]
        if entry.hasTranscript { links.append("[Transcripción](\(name)/\(SessionFiles.transcriptMD))") }
        if entry.hasMinutes { links.append("[Minuta](\(name)/\(SessionFiles.minutes))") }
        lines.append(links.joined(separator: " · "))

        return lines
    }

    /// A calendar title is someone else's text: its markdown-significant
    /// characters are escaped so it cannot turn into a link, a heading or
    /// emphasis (the title is one line, so `#` can only start it).
    static func escapeMarkdown(_ text: String) -> String {
        var out = ""
        for (index, character) in text.enumerated() {
            if "\\*_[]`".contains(character) || (index == 0 && character == "#") { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static func capitalized(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
