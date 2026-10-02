import Foundation

/// What the detail column shows, decided by how many of the selected
/// rows the list actually shows: hidden rows never count, so a stale
/// multi-selection cannot open the bulk panel or be classified by surprise.
enum DetailMode: Equatable, Sendable {
    case none
    case single
    /// 2+ rows: "N seleccionadas · Clasificar como ▸".
    case bulk(Int)

    static func of(selectedVisible count: Int) -> DetailMode {
        switch count {
        case ..<1: .none
        case 1: .single
        default: .bulk(count)
        }
    }

    var bulkTitle: String? {
        guard case .bulk(let count) = self else { return nil }
        return Textos.Indice.seleccionadas(count)
    }
}

/// `DetailMode` with the data each case needs, so a view can switch on it
/// without a "cannot happen" branch.
enum DetailSelection {
    case none
    case single(MeetingEntry)
    case bulk(count: Int)

    /// "N seleccionadas"; nil unless bulk.
    var bulkTitle: String? {
        guard case .bulk(let count) = self else { return nil }
        return Textos.Indice.seleccionadas(count)
    }
}

