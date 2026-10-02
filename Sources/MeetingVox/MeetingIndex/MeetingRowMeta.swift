import Foundation

/// The text of a main-window list row (the section header already gives the
/// day): `10:53 · 42 min · Teams`, and the row's title. Pure.
enum MeetingRowMeta {
    static func text(started: Date?, ended: Date?, durationSeconds: Int?, app: String?, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var parts: [String] = []
        if let started {
            parts.append(MeetingRowHeader.clock(started, calendar))
            if let end = MeetingRowHeader.end(started: started, ended: ended, durationSeconds: durationSeconds) {
                parts.append(Textos.Indice.duracion(minutos: Int((end.timeIntervalSince(started) / 60).rounded())))
            }
        } else if let durationSeconds, durationSeconds >= 0 {
            parts.append(Textos.Indice.duracion(minutos: Int((Double(durationSeconds) / 60).rounded())))
        }
        parts.append(appName(app))
        return parts.joined(separator: " · ")
    }

    /// The row's title: the linked calendar event's, else the summary's, or
    /// "Sin título" while there is neither (`SessionTitle`).
    static func title(summaryTitle: String?, calendarTitle: String? = nil) -> String {
        SessionTitle.resolve(calendar: calendarTitle, summary: summaryTitle, header: nil) ?? Textos.Principal.sinResumenFila
    }

    /// nil = a manual recording. An id no longer in the rule table shows raw.
    static func appName(_ id: String?) -> String {
        guard let id else { return Textos.Principal.grabacionManual }
        return MeetingApp.all.first(where: { $0.id == id })?.shortName ?? id
    }

    /// What VoiceOver says for a row's ámbito dot.
    static func ambitoAccessibilityLabel(_ ambito: Ambito?) -> String {
        Textos.Principal.ambitoDe(ambito?.label ?? Textos.Indice.sinClasificar)
    }
}
