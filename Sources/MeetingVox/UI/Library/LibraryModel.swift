import Foundation
import Observation

/// Biblioteca: the two editors the main window hosts, Plantillas and Glosario.
/// It only holds them and refreshes the one whose page is shown, so a
/// template added by hand or a glossary edited from another window is there
/// when the user looks. Both are injected, so tests and the headless
/// snapshots run over temp folders and the fake key store.
///
/// The editors outlive their page: an unsaved template edit survives a visit
/// to Reuniones and back (a refresh re-lists the folder but never touches the
/// open text).
@MainActor
@Observable
final class LibraryModel {
    let templates: TemplateEditorModel
    /// The glossary is the existing `SettingsModel` glossary, passed in
    /// explicitly: a second instance beside Ajustes' own, both writing through
    /// the config file and re-reading it when shown.
    let glossary: SettingsModel

    init(templates: TemplateEditorModel, glossary: SettingsModel) {
        self.templates = templates
        self.glossary = glossary
    }

    /// Re-read what `item`'s page shows; any other entry refreshes nothing.
    func refresh(for item: SidebarItem) {
        switch item {
        case .plantillas: templates.reload()
        case .glosario: glossary.reload()
        case .reuniones, .tareas, .ambito, .sinClasificar: break
        }
    }
}

extension TemplateEditorModel.Failure {
    /// The sentence the editor shows for this failure.
    var message: String {
        switch self {
        case .changedOnDisk: Textos.Biblioteca.archivoCambio
        case .writeFailed(let detail): Textos.Biblioteca.errorEscritura(detail)
        case .invalidID: Textos.Biblioteca.idInvalido
        case .exists: Textos.Biblioteca.idExiste
        case .notEditable: Textos.Biblioteca.noEditable
        case .notFactory: Textos.Biblioteca.noEsDeFabrica
        case .restoreFailed(let detail): Textos.Biblioteca.errorRestaurar(detail)
        case .backupFailed(let detail): Textos.Biblioteca.errorCopia(detail)
        case .unsavedChanges: Textos.Biblioteca.crearConCambios
        }
    }
}
