import Foundation
import Testing
@testable import MeetingVox

// MARK: - Parsing

@Suite struct MinutesTemplateParseTests {
    @Test func happyPath() {
        let t = MinutesTemplate.parse(id: "x", contents: """
        ---
        nombre: Minuta general
        descripcion: Resumen estándar.
        ---

        # Cuerpo
        texto
        """)
        #expect(t == MinutesTemplate(id: "x", nombre: "Minuta general", descripcion: "Resumen estándar.", cuerpo: "# Cuerpo\ntexto"))
    }

    @Test func noFrontmatterUsesWholeTextAsBody() {
        let t = MinutesTemplate.parse(id: "libre", contents: "\n  # Solo cuerpo\nlínea\n")
        #expect(t.nombre == "libre")
        #expect(t.descripcion == "")
        #expect(t.cuerpo == "# Solo cuerpo\nlínea")
    }

    @Test func unclosedFrontmatterFallsBack() {
        let text = "---\nnombre: A\nsin cierre"
        let t = MinutesTemplate.parse(id: "roto", contents: text)
        #expect(t.nombre == "roto")
        #expect(t.cuerpo == text)
    }

    @Test func crlf() {
        let t = MinutesTemplate.parse(id: "x", contents: "---\r\nnombre: A\r\ndescripcion: B\r\n---\r\ncuerpo\r\nfin\r\n")
        #expect(t.nombre == "A")
        #expect(t.descripcion == "B")
        #expect(t.cuerpo == "cuerpo\nfin")
    }

    @Test func colonInsideValue() {
        let t = MinutesTemplate.parse(id: "x", contents: "---\nnombre: Cliente: Proveedor\ndescripcion: a: b: c\n---\nc")
        #expect(t.nombre == "Cliente: Proveedor")
        #expect(t.descripcion == "a: b: c")
    }

    @Test func quotedValues() {
        let t = MinutesTemplate.parse(id: "x", contents: "---\nnombre: \"Con comillas\"\ndescripcion: 'simples'\n---\nc")
        #expect(t.nombre == "Con comillas")
        #expect(t.descripcion == "simples")
    }

    @Test func emptyNombreFallsBackToId() {
        let t = MinutesTemplate.parse(id: "x", contents: "---\nnombre:\n---\nc")
        #expect(t.nombre == "x")
    }

    @Test func fileContentsRoundTrips() {
        for factory in FactoryTemplates.all {
            #expect(MinutesTemplate.parse(id: factory.id, contents: factory.fileContents) == factory)
        }
    }
}

// MARK: - Factory templates

@Suite struct FactoryTemplatesTests {
    @Test func sevenExpectedIds() {
        #expect(FactoryTemplates.ids == ["general", "comercial", "daily", "uno-a-uno", "levantamiento", "entrevista", "familiar"])
    }

    @Test func familiarTemplateMatchesTheSpec() {
        let t = MinutesTemplate.parse(id: "familiar", contents: FactoryTemplates.familiar.fileContents)
        #expect(t.nombre == "Reunión familiar")
        #expect(t.descripcion == "Conversación familiar: temas, acuerdos, tareas y fechas importantes.")
        #expect(t.cuerpo.contains("## Participantes\n- Yo: el nombre de quien grabó la reunión"))
        for section in [
            "## Temas conversados", "## Decisiones y acuerdos", "## Tareas", "## Fechas importantes",
            "## Gastos y montos mencionados", "## Pendientes para la próxima conversación",
        ] {
            #expect(t.cuerpo.contains(section), "\(section)")
        }
        #expect(t.cuerpo.contains("| Quién | Qué | Para cuándo |"))
        #expect(t.cuerpo.contains("sin citas textuales"))
        #expect(!t.cuerpo.contains("## Asistentes"))
    }

    @Test(arguments: FactoryTemplates.all)
    func parsesWithNonEmptyFields(_ factory: MinutesTemplate) {
        let t = MinutesTemplate.parse(id: factory.id, contents: factory.fileContents)
        #expect(!t.nombre.isEmpty && t.nombre != t.id)
        #expect(!t.descripcion.isEmpty)
        #expect(!t.cuerpo.isEmpty)
        #expect(t.cuerpo.contains("No se mencionó"))
    }

    @Test func bodiesAreTheUserApprovedVersions() {
        #expect(FactoryTemplates.general.cuerpo.contains("## Asistentes\n- Yo: el nombre de quien grabó la reunión"))
        #expect(FactoryTemplates.general.cuerpo.contains("## Personas mencionadas"))
        #expect(FactoryTemplates.comercial.nombre == "Llamada comercial")
        #expect(FactoryTemplates.comercial.cuerpo.contains("## Participantes\n- Por nuestro equipo: ..."))
        #expect(FactoryTemplates.daily.cuerpo.contains("## Oportunidades mencionadas"))
        #expect(FactoryTemplates.daily.cuerpo.contains("## Bloqueos que requieren seguimiento"))
        #expect(FactoryTemplates.unoAUno.cuerpo.contains("## Participante\n- Nombre y rol"))
        #expect(FactoryTemplates.levantamiento.cuerpo.contains("## Sistemas mencionados"))
        #expect(FactoryTemplates.entrevista.cuerpo.contains("## Perfil del candidato"))
        for template in FactoryTemplates.all {
            #expect(template.cuerpo.contains("Estructura de salida:"), "\(template.id)")
            #expect(template.cuerpo.contains("Glosario (términos que la transcripción suele deformar):"), "\(template.id)")
            #expect(!template.cuerpo.hasPrefix(" "), "\(template.id) keeps literal indentation")
        }
    }
}

// MARK: - Store

@Suite struct TemplateStoreTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("plantillas", isDirectory: true)
    }

    private func write(_ text: String, id: String) throws {
        try Data(text.utf8).write(to: TemplateStore.fileURL(id: id, in: dir))
    }

    private func read(id: String) throws -> String {
        try String(contentsOf: TemplateStore.fileURL(id: id, in: dir), encoding: .utf8)
    }

    @Test func installCreatesDirAndAllFactoryFiles() throws {
        try TemplateStore.installFactoryTemplatesIfMissing(in: dir)
        #expect(Set(TemplateStore.list(in: dir).map(\.id)) == Set(FactoryTemplates.ids))
    }

    @Test func installDoesNotOverwriteModifiedFactoryFile() throws {
        try TemplateStore.installFactoryTemplatesIfMissing(in: dir)
        let edited = "---\nnombre: Mi general\n---\neditado"
        try write(edited, id: "general")
        try TemplateStore.installFactoryTemplatesIfMissing(in: dir)
        #expect(try read(id: "general") == edited)
    }

    @Test func installRecreatesDeletedFactoryFile() throws {
        try TemplateStore.installFactoryTemplatesIfMissing(in: dir)
        try FileManager.default.removeItem(at: TemplateStore.fileURL(id: "daily", in: dir))
        try TemplateStore.installFactoryTemplatesIfMissing(in: dir)
        #expect(TemplateStore.template(id: "daily", in: dir) == FactoryTemplates.daily)
    }

    @Test func installAddsFamiliarToAnExistingFolderWithoutTouchingEditedFiles() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let edited = "---\nnombre: Mi general\n---\neditado"
        try write(edited, id: "general")

        try TemplateStore.installFactoryTemplatesIfMissing(in: dir)

        #expect(try read(id: "general") == edited)
        #expect(TemplateStore.template(id: "familiar", in: dir) == FactoryTemplates.familiar)
    }

    @Test func restoreOverwritesFactoryButKeepsCustom() throws {
        try TemplateStore.installFactoryTemplatesIfMissing(in: dir)
        try write("editado", id: "general")
        let custom = "---\nnombre: Mía\n---\npropia"
        try write(custom, id: "mia")

        try TemplateStore.restoreFactoryTemplate(id: "general", in: dir)

        #expect(TemplateStore.template(id: "general", in: dir) == FactoryTemplates.general)
        #expect(try read(id: "mia") == custom)
    }

    @Test func listSortsByNombreAndSkipsNonMarkdown() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("---\nnombre: beta\n---\nb", id: "z")
        try write("---\nnombre: Álgebra\n---\na", id: "y")
        try write("---\nnombre: Carta\n---\nc", id: "a")
        try Data("ignorar".utf8).write(to: dir.appendingPathComponent("notas.txt"))

        #expect(TemplateStore.list(in: dir).map(\.nombre) == ["Álgebra", "beta", "Carta"])
    }

    @Test func missingTemplateIsNil() {
        #expect(TemplateStore.template(id: "nada", in: dir) == nil)
        #expect(TemplateStore.list(in: dir).isEmpty)
    }
}
