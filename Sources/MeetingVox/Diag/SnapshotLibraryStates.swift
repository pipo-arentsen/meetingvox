import SwiftUI

/// Biblioteca's snapshot states: the template editor clean, dirty,
/// with an unreadable file and after the disk changed under an edit, plus the
/// Glosario page. Full-window states use `flatColumns` like the earlier
/// units. Every state that writes to a templates folder gets a folder of its
/// own under the temp root, so states never see each other's files and the
/// real templates are never involved.
enum SnapshotLibraryStates {
    static let windowSize = MainLayout.defaultSize

    @MainActor
    static var all: [SnapshotState] {
        [plantillas, plantillasEmpty, plantillasDirty, plantillasUnreadable, plantillasBackup, plantillasChanged, glosario]
    }

    /// The window on `item` over a Biblioteca whose templates live in a
    /// fresh folder (factory templates installed) named `folder`.
    @MainActor
    private static func window(
        _ context: SnapshotContext, folder: String, showing item: SidebarItem,
        prepare: (TemplateEditorModel, URL) throws -> Void = { _, _ in }
    ) -> AnyView {
        let dir = context.env.tempRoot.appendingPathComponent(folder, isDirectory: true)
        try? TemplateStore.installFactoryTemplatesIfMissing(in: dir)
        let library = LibraryModel(
            templates: TemplateEditorModel(dir: dir), glossary: context.env.makeSettingsModel()
        )
        try? prepare(library.templates, dir)
        let model = context.env.makeMainWindowModel(library: library)
        SnapshotEnvironment.load(model)
        model.sidebar = item
        return AnyView(MainView(model: model, onToggleRecording: {}, flatColumns: true))
    }

    /// A factory template open, nothing edited.
    @MainActor
    static let plantillas = SnapshotState(name: "library-plantillas", width: windowSize.width, height: windowSize.height) {
        window($0, folder: "lib-clean", showing: .plantillas) { editor, _ in
            editor.reload()
            editor.select("comercial")
        }
    }

    /// Nothing selected yet.
    @MainActor
    static let plantillasEmpty = SnapshotState(name: "library-plantillas-empty", width: windowSize.width, height: windowSize.height) {
        window($0, folder: "lib-empty", showing: .plantillas)
    }

    /// An edit in progress: the "Sin guardar" mark, Revertir and Guardar on.
    @MainActor
    static let plantillasDirty = SnapshotState(name: "library-plantillas-dirty", width: windowSize.width, height: windowSize.height) {
        window($0, folder: "lib-dirty", showing: .plantillas) { editor, _ in
            editor.reload()
            editor.select("general")
            editor.text = editor.text.replacingOccurrences(of: "Objetivo:", with: "Objetivo (ajustado):")
        }
    }

    /// A file that is not UTF-8 stays listed (warning mark) and opens with
    /// the invalid-bytes banner.
    @MainActor
    static let plantillasUnreadable = SnapshotState(name: "library-plantillas-unreadable", width: windowSize.width, height: windowSize.height) {
        window($0, folder: "lib-unreadable", showing: .plantillas) { editor, dir in
            var bytes = Data("---\nnombre: Plantilla antigua \n".utf8)
            bytes.append(0xE9)
            bytes.append(Data("\ndescripcion: Guardada con otra codificación\n---\n\n# Minuta\n\n## Acuerdos\n- Pendiente de revisar.\n".utf8))
            try bytes.write(to: TemplateStore.fileURL(id: "antigua", in: dir))
            editor.reload()
            editor.select("antigua")
        }
    }

    /// The same file after its first save: the original bytes were kept
    /// beside it and the banner says so.
    @MainActor
    static let plantillasBackup = SnapshotState(name: "library-plantillas-backup", width: windowSize.width, height: windowSize.height) {
        window($0, folder: "lib-backup", showing: .plantillas) { editor, dir in
            var bytes = Data("---\nnombre: Plantilla antigua \n".utf8)
            bytes.append(0xE9)
            bytes.append(Data("\ndescripcion: Guardada con otra codificación\n---\n\n# Minuta\n\n## Acuerdos\n- Pendiente de revisar.\n".utf8))
            try bytes.write(to: TemplateStore.fileURL(id: "antigua", in: dir))
            editor.reload()
            editor.select("antigua")
            editor.save()
        }
    }

    /// The file changed on disk after it was opened and the edit was saved:
    /// the save is refused with "El archivo cambió en disco" and "Recargar".
    @MainActor
    static let plantillasChanged = SnapshotState(name: "library-plantillas-changed", width: windowSize.width, height: windowSize.height) {
        window($0, folder: "lib-changed", showing: .plantillas) { editor, dir in
            editor.reload()
            editor.select("daily")
            editor.text = editor.text + "\n- Mi cambio sin guardar."
            let url = TemplateStore.fileURL(id: "daily", in: dir)
            try Data("---\nnombre: Daily\n---\nEditada por otra herramienta.\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: url.path)
            editor.save()
        }
    }

    /// The moved glossary: note and add form, entries with their checkbox.
    @MainActor
    static let glosario = SnapshotState(name: "library-glosario", width: windowSize.width, height: windowSize.height) {
        window($0, folder: "lib-glosario", showing: .glosario)
    }
}
