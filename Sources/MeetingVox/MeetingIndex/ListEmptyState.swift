import Foundation

/// Why the main window's list has nothing to show, if it doesn't. Pure.
enum ListEmptyState: Equatable, Sendable {
    /// The first scan has not published yet.
    case loading
    /// The recordings root has no sessions at all.
    case emptyRoot
    /// There are sessions but the search or filters hide every one.
    case noMatches

    /// - Parameters:
    ///   - hasLoaded: the first scan has published.
    ///   - total: every session on disk.
    ///   - shown: rows the list would draw.
    /// - Returns: nil when there are rows to draw (they win over any state,
    ///   including a rescan in flight).
    static func of(hasLoaded: Bool, total: Int, shown: Int) -> ListEmptyState? {
        if shown > 0 { return nil }
        if !hasLoaded { return .loading }
        return total == 0 ? .emptyRoot : .noMatches
    }

    var title: String {
        switch self {
        case .loading: Textos.Principal.cargando
        case .emptyRoot: Textos.Principal.sinReunionesTitulo
        case .noMatches: Textos.Indice.sinReuniones
        }
    }

    var detail: String? {
        self == .emptyRoot ? Textos.Principal.sinReunionesDetalle : nil
    }
}
