import Foundation
import Testing

@testable import MeetingVox

/// The Biblioteca editor's view of the templates folder (LE-1, LE-3): every
/// `*.md` listed even when it cannot be read as UTF-8, and a factory restore
/// that touches one factory id and nothing else.
@Suite("TemplateStoreFiles")
struct TemplateStoreFilesTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("plantillas", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func write(_ text: String, id: String) throws {
        try Data(text.utf8).write(to: TemplateStore.fileURL(id: id, in: dir))
    }

    private func read(id: String) throws -> String {
        try String(contentsOf: TemplateStore.fileURL(id: id, in: dir), encoding: .utf8)
    }

    /// Latin-1 "é" (0xE9) is not valid UTF-8 on its own.
    private func writeInvalidUTF8(id: String) throws {
        var bytes = Data("---\nnombre: Vieja ".utf8)
        bytes.append(0xE9)
        bytes.append(Data("\n---\ncuerpo".utf8))
        try bytes.write(to: TemplateStore.fileURL(id: id, in: dir))
    }

    // MARK: - files(in:)

    @Test func listsEveryMarkdownFileSortedByNameAndSkipsTheRest() throws {
        try write("---\nnombre: beta\n---\nb", id: "z")
        try write("---\nnombre: Álgebra\n---\na", id: "a")
        try write("sin frontmatter", id: "carta")
        try Data("x".utf8).write(to: dir.appendingPathComponent("notas.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".oculta.md"))

        let files = TemplateStore.files(in: dir)

        #expect(files.map(\.id) == ["a", "z", "carta"])
        #expect(files.map(\.title) == ["Álgebra", "beta", "carta"])
        #expect(files.allSatisfy { $0.readError == nil && !$0.lossy })
        #expect(files[0].text == "---\nnombre: Álgebra\n---\na")
        // Directory listings report the resolved path (/private/var), so compare resolved.
        #expect(files[0].url.resolvingSymlinksInPath() == TemplateStore.fileURL(id: "a", in: dir).resolvingSymlinksInPath())
    }

    @Test func aFileThatIsNotUTF8StaysListedLossyAndEditable() throws {
        try write("---\nnombre: Buena\n---\nb", id: "buena")
        try writeInvalidUTF8(id: "vieja")

        let files = TemplateStore.files(in: dir)

        #expect(files.map(\.id) == ["buena", "vieja"])
        let bad = try #require(files.first { $0.id == "vieja" })
        #expect(bad.lossy)
        #expect(bad.readError == nil)
        #expect(bad.text.contains("\u{FFFD}"))
        #expect(bad.text.contains("cuerpo"))
        // The tolerant parser still reads the frontmatter around the bad byte.
        #expect(bad.template?.nombre == "Vieja \u{FFFD}")
        #expect(files.first { $0.id == "buena" }?.lossy == false)
        // `TemplateStore.list` (what the generation flow uses) is unchanged: it skips it.
        #expect(TemplateStore.list(in: dir).map(\.id) == ["buena"])
    }

    @Test(.enabled(if: geteuid() != 0, "root ignores file permissions"))
    func aFileTheSystemRefusesToReadIsListedWithItsErrorAndNoText() throws {
        try write("---\nnombre: Cerrada\n---\nx", id: "cerrada")
        let url = TemplateStore.fileURL(id: "cerrada", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let file = try #require(TemplateStore.files(in: dir).first)

        #expect(file.id == "cerrada")
        #expect(file.readError != nil)
        #expect(file.text.isEmpty)
        #expect(file.template == nil)
        #expect(file.title == "cerrada")
    }

    @Test func eachFileCarriesTheModificationDateItHadWhenRead() throws {
        try write("a", id: "uno")
        let url = TemplateStore.fileURL(id: "uno", in: dir)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        #expect(TemplateStore.files(in: dir).first?.modified == stamp)
        #expect(TemplateStore.modificationDate(of: url) == stamp)
        #expect(TemplateStore.modificationDate(of: dir.appendingPathComponent("nada.md")) == nil)
    }

    @Test func aMissingFolderListsNothing() {
        #expect(TemplateStore.files(in: dir.appendingPathComponent("no-existe")).isEmpty)
    }

    @Test func fileByIDReadsOneAndRejectsInvalidOrMissingIDs() throws {
        try write("---\nnombre: Una\n---\ncuerpo", id: "una")

        #expect(TemplateStore.file(id: "una", in: dir)?.title == "Una")
        #expect(TemplateStore.file(id: "nada", in: dir) == nil)
        #expect(TemplateStore.file(id: "../una", in: dir) == nil)
        #expect(TemplateStore.file(id: ".una", in: dir) == nil)
    }

    // MARK: - restoreFactoryTemplate(id:in:)

    @Test func restoringOneFactoryIDRewritesOnlyThatFile() throws {
        try TemplateStore.installFactoryTemplatesIfMissing(in: dir)
        try write("editado general", id: "general")
        try write("editado daily", id: "daily")

        try TemplateStore.restoreFactoryTemplate(id: "general", in: dir)

        #expect(TemplateStore.template(id: "general", in: dir) == FactoryTemplates.general)
        #expect(try read(id: "daily") == "editado daily")
    }

    @Test func restoreLeavesAUserTemplateAloneEvenWhenAFactoryOneIsEdited() throws {
        try TemplateStore.installFactoryTemplatesIfMissing(in: dir)
        try write("editado", id: "general")
        let custom = "---\nnombre: Cliente X\n---\npropia"
        try write(custom, id: "cliente-x")

        try TemplateStore.restoreFactoryTemplate(id: "general", in: dir)

        #expect(TemplateStore.template(id: "general", in: dir) == FactoryTemplates.general)
        #expect(try read(id: "cliente-x") == custom)
    }

    @Test func restoringANonFactoryIDIsRefusedAndTouchesNothing() throws {
        let custom = "---\nnombre: Cliente X\n---\npropia"
        try write(custom, id: "cliente-x")

        #expect(throws: TemplateStore.RestoreError.notFactory("cliente-x")) {
            try TemplateStore.restoreFactoryTemplate(id: "cliente-x", in: dir)
        }
        #expect(try read(id: "cliente-x") == custom)
        #expect(TemplateStore.files(in: dir).map(\.id) == ["cliente-x"])
    }

    @Test func aPathLikeIDNeverEscapesTheFolder() throws {
        #expect(throws: TemplateStore.RestoreError.self) {
            try TemplateStore.restoreFactoryTemplate(id: "../general", in: dir)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("general.md").path))
    }

    @Test func restoringAFactoryIDWhoseFileWasDeletedBringsItBack() throws {
        try TemplateStore.installFactoryTemplatesIfMissing(in: dir)
        try FileManager.default.removeItem(at: TemplateStore.fileURL(id: "familiar", in: dir))

        try TemplateStore.restoreFactoryTemplate(id: "familiar", in: dir)

        #expect(TemplateStore.template(id: "familiar", in: dir) == FactoryTemplates.familiar)
    }

    @Test func factoryIDsAreExactlyTheShippedOnes() {
        for id in FactoryTemplates.ids { #expect(TemplateStore.isFactoryID(id), "\(id)") }
        #expect(!TemplateStore.isFactoryID("cliente-x"))
        #expect(!TemplateStore.isFactoryID("General")) // ids are file stems: case matters
    }
}
