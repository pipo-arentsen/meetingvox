import Foundation

/// Where an "open this" request lands now that the window renders minutes.
/// `minuta.md` selects its session on the Minuta tab; anything else (the
/// transcript, a manual `minuta.<id>.md`) still opens in another app (DT-4).
/// Pure: the caller does the opening.
enum OpenTarget: Equatable {
    /// Select the session in the window; `tab` nil leaves the current tab.
    case session(URL, tab: DetailTab?)
    case external(URL)

    static func decide(file: URL) -> OpenTarget {
        file.lastPathComponent == SessionFiles.minutes
            ? .session(file.deletingLastPathComponent(), tab: .minuta) : .external(file)
    }

    /// "Abrir" on a notice or "Última": the minutes when there are any.
    static func decide(opening dir: URL, hasMinutes: Bool) -> OpenTarget {
        .session(dir, tab: hasMinutes ? .minuta : .resumen)
    }

    /// "Ver reunión", or a retry the stage refused: the session, on the Minuta
    /// tab when it was the minutes that had nothing to retry (the tab says why).
    static func decide(showing dir: URL, refusedStage: Notice.Stage?) -> OpenTarget {
        .session(dir, tab: refusedStage == .minutes ? .minuta : nil)
    }
}
