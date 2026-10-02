import Foundation
import Testing

@testable import MeetingVox

/// A `LibraryModel` over its own temp folder: templates dir, config file and
/// the fake key store, none of them the real ones. Shared by the tests that
/// need a `MainWindowModel`.
@MainActor
enum TestLibrary {
    static func make(root: URL? = nil, config: [String: Any] = [:]) throws -> (library: LibraryModel, root: URL) {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-library-\(UUID().uuidString)", isDirectory: true)
        let templates = root.appendingPathComponent("plantillas", isDirectory: true)
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)
        let library = LibraryModel(
            templates: TemplateEditorModel(dir: templates),
            glossary: SettingsModel(configURL: configURL, templatesDir: templates, keychain: SnapshotKeyStore())
        )
        return (library, root)
    }
}

/// The Biblioteca's two editors refresh from disk when their page is shown,
/// so a template added by hand or a glossary edited in another window is
/// there when the user looks (the models outlive the page).
@MainActor
@Suite("LibraryModel")
struct LibraryModelTests {
    private func write(_ text: String, id: String, in root: URL) throws {
        let dir = root.appendingPathComponent("plantillas", isDirectory: true)
        try Data(text.utf8).write(to: TemplateStore.fileURL(id: id, in: dir))
    }

    private func writeConfig(_ object: [String: Any], in root: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("config.json"))
    }

    @Test func showingPlantillasRelistsTheFolderAndLeavesTheGlossaryAlone() throws {
        let (library, root) = try TestLibrary.make(config: ["glossary": ["Uno"]])
        try write("---\nnombre: Externa\n---\nx", id: "externa", in: root)
        try writeConfig(["glossary": ["Uno", "Dos"]], in: root)

        library.refresh(for: .plantillas)

        #expect(library.templates.files.map(\.id) == ["externa"])
        #expect(library.glossary.glossary.map(\.term) == ["Uno"])
    }

    @Test func showingGlosarioRereadsTheConfigAndLeavesTheTemplatesAlone() throws {
        let (library, root) = try TestLibrary.make(config: ["glossary": ["Uno"]])
        try write("---\nnombre: Externa\n---\nx", id: "externa", in: root)
        try writeConfig(["glossary": ["Uno", "Dos"]], in: root)

        library.refresh(for: .glosario)

        #expect(library.glossary.glossary.map(\.term) == ["Uno", "Dos"])
        #expect(library.templates.files.isEmpty)
    }

    @Test func otherPagesRefreshNothing() throws {
        let (library, root) = try TestLibrary.make(config: ["glossary": ["Uno"]])
        try write("---\nnombre: Externa\n---\nx", id: "externa", in: root)
        try writeConfig(["glossary": ["Uno", "Dos"]], in: root)

        for item in [SidebarItem.reuniones, .tareas, .ambito(.trabajo), .sinClasificar] {
            library.refresh(for: item)
        }

        #expect(library.templates.files.isEmpty)
        #expect(library.glossary.glossary.map(\.term) == ["Uno"])
    }

    @Test func refreshingTheTemplatesKeepsAnEditInProgress() throws {
        let (library, root) = try TestLibrary.make()
        try write("---\nnombre: Mía\n---\nx", id: "mia", in: root)
        library.refresh(for: .plantillas)
        library.templates.select("mia")
        library.templates.text = "en edición"

        try write("---\nnombre: Otra\n---\ny", id: "otra", in: root)
        library.refresh(for: .plantillas)

        #expect(library.templates.files.map(\.id).sorted() == ["mia", "otra"])
        #expect(library.templates.text == "en edición")
        #expect(library.templates.isDirty)
    }
}

/// The window model wires the sidebar to the refresh, and keeps the editors
/// (and an unsaved edit) while the user visits other pages.
@MainActor
@Suite("LibrarySidebar")
struct LibrarySidebarTests {
    private func makeWindow(config: [String: Any] = [:]) throws -> (MainWindowModel, URL) {
        let (library, root) = try TestLibrary.make(config: config)
        let meetings = MeetingsModel(
            root: root.appendingPathComponent("Recordings", isDirectory: true), config: { ConfigValues(raw: [:]) }
        )
        let model = MainWindowModel(
            meetings: meetings, store: PipelineStatusStore(), calendar: .current, now: { Date() }, library: library
        )
        return (model, root)
    }

    @Test func choosingPlantillasInTheSidebarListsTheTemplates() throws {
        let (model, root) = try makeWindow()
        try Data("---\nnombre: Externa\n---\nx".utf8)
            .write(to: TemplateStore.fileURL(id: "externa", in: root.appendingPathComponent("plantillas")))
        #expect(model.library.templates.files.isEmpty)

        model.sidebar = .plantillas

        #expect(model.library.templates.files.map(\.id) == ["externa"])
    }

    @Test func choosingGlosarioInTheSidebarRereadsTheGlossary() throws {
        let (model, root) = try makeWindow(config: ["glossary": ["Uno"]])
        try JSONSerialization.data(withJSONObject: ["glossary": ["Uno", "Dos"]])
            .write(to: root.appendingPathComponent("config.json"))

        model.sidebar = .glosario

        #expect(model.library.glossary.glossary.map(\.term) == ["Uno", "Dos"])
    }

    @Test func leavingPlantillasAndComingBackKeepsTheUnsavedEdit() throws {
        let (model, root) = try makeWindow()
        try Data("---\nnombre: Mía\n---\nx".utf8)
            .write(to: TemplateStore.fileURL(id: "mia", in: root.appendingPathComponent("plantillas")))
        model.sidebar = .plantillas
        model.library.templates.select("mia")
        model.library.templates.text = "en edición"

        model.sidebar = .reuniones
        model.sidebar = .plantillas

        #expect(model.library.templates.selectedID == "mia")
        #expect(model.library.templates.text == "en edición")
    }
}
