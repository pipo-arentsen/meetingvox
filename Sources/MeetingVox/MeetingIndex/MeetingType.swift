import Foundation

/// A session's "Tipo" in the main window: the template of its
/// minutes. Derived on every read, never stored; to change it the user
/// regenerates the minutes with another template.
enum MeetingType: Hashable, Sendable {
    /// A template id. Its label is the template's `nombre`, or the id when
    /// that template no longer exists.
    case template(String)
    /// Minutes with no template this app can tell (no provenance header, no
    /// meta.json choice) — e.g. a hand-written `minuta.md`.
    case unknown
    /// No minutes and no template chosen for them.
    case noMinutes

    /// Order: meta.json `minutes_template` when it names an existing
    /// template; else the `template:` of `minuta.md`'s header; else
    /// meta.json's id even though its template was deleted; else `.unknown`
    /// (with minutes) or `.noMinutes`. Ids failing `TemplateStore.isValidID`
    /// are ignored. The header only counts while `minuta.md` exists.
    static func of(_ entry: MeetingEntry, knownTemplateIDs: Set<String>) -> MeetingType {
        let meta = entry.metaTemplateID.flatMap { TemplateStore.isValidID($0) ? $0 : nil }
        let header = entry.hasMinutes ? entry.minutesTemplateID.flatMap { TemplateStore.isValidID($0) ? $0 : nil } : nil
        if let meta, knownTemplateIDs.contains(meta) { return .template(meta) }
        if let header { return .template(header) }
        if let meta { return .template(meta) }
        return entry.hasMinutes ? .unknown : .noMinutes
    }
}

extension MeetingType {
    /// The template's `nombre`, or its id when the template no longer exists
    /// (`templates` = `TemplateStore.list` as the window last read it).
    func label(templates: [MinutesTemplate]) -> String {
        switch self {
        case .template(let id): templates.first { $0.id == id }?.nombre ?? id
        case .unknown: Textos.Indice.sinPlantilla
        case .noMinutes: Textos.Indice.sinMinuta
        }
    }
}
