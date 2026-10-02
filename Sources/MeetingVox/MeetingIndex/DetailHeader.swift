import Foundation

/// The text and chips of the session detail's header: the title, the
/// meta line `Jue 24 sep · 10:53–11:35 (42 min) · Teams · Plantilla: …`, and
/// the ámbito, cliente and tracks chips. Pure.
struct DetailHeader: Equatable, Sendable {
    let title: String
    let meta: String
    /// nil = "Sin clasificar".
    let ambito: Ambito?
    /// nil when the summary names none (or a blank one).
    let client: String?
    /// "Yo · Otros" / "Yo" / "Otros"; nil when meta.json lists no tracks.
    let pistas: String?

    /// - Parameters:
    ///   - type: the session's `MeetingType`; only a template adds the
    ///     "Plantilla" part (unknown or absent minutes have none to name).
    ///   - templates: as the list last read them, to turn an id into a name.
    static func make(entry: MeetingEntry, type: MeetingType, templates: [MinutesTemplate], timeZone: TimeZone) -> DetailHeader {
        var parts = [
            MeetingRowHeader.text(
                started: entry.started, ended: entry.ended, durationSeconds: entry.durationSeconds, timeZone: timeZone
            ) ?? entry.dir.lastPathComponent,
            MeetingRowMeta.appName(entry.app),
        ]
        if case .template = type {
            parts.append(Textos.Principal.plantillaDe(type.label(templates: templates)))
        }
        return DetailHeader(
            title: MeetingRowMeta.title(summaryTitle: entry.summary?.title, calendarTitle: entry.calendarEvent?.title),
            meta: parts.joined(separator: " · "),
            ambito: entry.ambito,
            client: entry.summary?.client.flatMap { trimmed in
                let value = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            },
            pistas: pistas(entry.tracks)
        )
    }

    /// `mic` is the user, `system` is the other side.
    static func pistas(_ tracks: Set<String>) -> String? {
        var names: [String] = []
        if tracks.contains("mic") { names.append(Textos.Principal.pistaYo) }
        if tracks.contains("system") { names.append(Textos.Principal.pistaOtros) }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }
}
