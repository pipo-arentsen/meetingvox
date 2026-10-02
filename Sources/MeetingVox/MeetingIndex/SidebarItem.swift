import Foundation

/// One selectable entry of the main window's sidebar. Pure.
///
/// Reuniones and the ámbito entries drive the list's ámbito filter; the two
/// Biblioteca entries open their editors (Plantillas, Glosario); Tareas opens
/// the tasks page. None of those three touches the list filter.
enum SidebarItem: Hashable, Sendable {
    case reuniones
    case tareas
    case ambito(Ambito)
    case sinClasificar
    case plantillas
    case glosario

    /// The ámbito entries in the order the sidebar shows them.
    static let ambitoItems: [SidebarItem] = Ambito.allCases.map(SidebarItem.ambito) + [.sinClasificar]
    static let bibliotecaItems: [SidebarItem] = [.plantillas, .glosario]

    /// The list filter this entry stands for; nil for an entry that has none.
    var ambitoFilter: AmbitoFilter? {
        switch self {
        case .reuniones: .all
        case .ambito(let ambito): .only(ambito)
        case .sinClasificar: .unclassified
        case .tareas, .plantillas, .glosario: nil
        }
    }

    /// A Biblioteca editor page instead of the meeting list.
    var isLibrary: Bool { self == .plantillas || self == .glosario }

    var label: String {
        switch self {
        case .reuniones: Textos.Principal.reuniones
        case .tareas: Textos.Principal.tareas
        case .ambito(let ambito): ambito.label
        case .sinClasificar: Textos.Indice.sinClasificar
        case .plantillas: Textos.Principal.plantillas
        case .glosario: Textos.Principal.glosario
        }
    }

    /// The one SF Symbol for the entry (the sidebar row). The ámbito entries
    /// are drawn as coloured dots instead, but still have one so the switch
    /// stays exhaustive.
    var icon: String {
        switch self {
        case .reuniones: "list.bullet"
        case .tareas: "checkmark.square"
        case .ambito, .sinClasificar: "circle.fill"
        case .plantillas: "doc.text"
        case .glosario: "textformat"
        }
    }
}
