import Foundation

/// A session's ámbito, stored as meta.json `ambito`. Only the
/// user sets it — nothing suggests, infers or defaults one — and it never
/// reaches Hindsight, minutes, summaries or `indice.md`.
enum Ambito: String, CaseIterable, Sendable, Hashable {
    case trabajo
    case profesional
    case personal

    /// A meta.json value: exactly one of the raw values, else nil ("Sin
    /// clasificar"). An unknown or non-string value never fails a read.
    init?(metaValue: Any?) {
        guard let raw = metaValue as? String, let value = Ambito(rawValue: raw) else { return nil }
        self = value
    }
}

extension Ambito {
    var label: String {
        switch self {
        case .trabajo: Textos.Indice.trabajo
        case .profesional: Textos.Indice.profesional
        case .personal: Textos.Indice.personal
        }
    }
}

/// The "Ámbito" filter: every session, one value, or those with
/// none.
enum AmbitoFilter: Hashable, Sendable {
    case all
    case only(Ambito)
    case unclassified

    func matches(_ ambito: Ambito?) -> Bool {
        switch self {
        case .all: true
        case .only(let wanted): ambito == wanted
        case .unclassified: ambito == nil
        }
    }
}
