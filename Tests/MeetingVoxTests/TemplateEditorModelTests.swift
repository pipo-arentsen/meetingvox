import Foundation
import Testing

@testable import MeetingVox

/// LE-1..LE-3 through the editor model: dirty/revert/save, the mtime guard,
/// an injected write failure leaving the original intact, restore limited to
/// factory ids, invalid ids, and unreadable files staying editable. Every
/// model runs over a temp folder; the writer and the clock of the files are
/// seams, so nothing here can touch the real templates.
@MainActor
@Suite("TemplateEditorModel")
struct TemplateEditorModelTests {
    let dir: URL
    let fm = FileManager.default
    /// Its own center and clock: nothing leaks to `.default`, and backup names are fixed.
    let center = NotificationCenter()
    static let fixedNow = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC

    init() throws {
        dir = fm.temporaryDirectory
            .appendingPathComponent("meetingvox-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("plantillas", isDirectory: true)
        try TemplateStore.installFactoryTemplatesIfMissing(in: dir)
    }

    private func model(write: (@Sendable (Data, URL) throws -> Void)? = nil) -> TemplateEditorModel {
        let now = Self.fixedNow
        let model = write.map { TemplateEditorModel(dir: dir, write: $0, now: { now }, notifications: center) }
            ?? TemplateEditorModel(dir: dir, now: { now }, notifications: center)
        model.reload()
        return model
    }

    private func write(_ text: String, id: String) throws {
        try Data(text.utf8).write(to: TemplateStore.fileURL(id: id, in: dir))
    }

    private func read(id: String) throws -> String {
        try String(contentsOf: TemplateStore.fileURL(id: id, in: dir), encoding: .utf8)
    }

    private func files() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private struct DiskFull: LocalizedError {
        var errorDescription: String? { "disco lleno" }
    }

    // MARK: - Listing and selecting

    @Test func listsTheTemplatesSortedByNameAndSelectsNothingAtFirst() {
        let model = model()

        #expect(Set(model.files.map(\.id)) == Set(FactoryTemplates.ids))
        #expect(model.files.map(\.title) == FactoryTemplates.all.map(\.nombre).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(model.selectedID == nil)
        #expect(!model.isDirty)
        #expect(!model.canSave)
    }

    @Test func selectingLoadsTheFileTextAsCleanAndReportsFactory() throws {
        try write("---\nnombre: Cliente X\n---\npropia", id: "cliente-x")
        let model = model()

        #expect(model.select("general") == .selected)
        #expect(model.selectedID == "general")
        #expect(model.text == FactoryTemplates.general.fileContents)
        #expect(!model.isDirty)
        #expect(model.isFactory)

        #expect(model.select("cliente-x") == .selected)
        #expect(model.text == "---\nnombre: Cliente X\n---\npropia")
        #expect(!model.isFactory)
    }

    @Test func aFileThatDisappearedCannotBeSelected() {
        let model = model()
        try? fm.removeItem(at: TemplateStore.fileURL(id: "daily", in: dir))

        #expect(model.select("daily") == .selected)
        #expect(model.selectedID == nil)
        #expect(model.files.map(\.id).contains("daily") == false)
    }

    // MARK: - Dirty, revert

    @Test func editingMakesItDirtyAndRevertRestoresTheLastSavedText() {
        let model = model()
        model.select("general")
        let original = model.text

        model.text = original + "\nextra"
        #expect(model.isDirty)
        #expect(model.canSave)

        model.revert()
        #expect(model.text == original)
        #expect(!model.isDirty)
    }

    @Test func typingBackTheSameTextIsClean() {
        let model = model()
        model.select("general")
        let original = model.text

        model.text = original + "x"
        model.text = original

        #expect(!model.isDirty)
    }

    // MARK: - Save

    @Test func saveWritesTheTextAtomicallyAndCleansTheState() throws {
        let model = model()
        model.select("general")
        model.text = "---\nnombre: Nuevo nombre\n---\ncuerpo nuevo\n"

        model.save()

        #expect(try read(id: "general") == "---\nnombre: Nuevo nombre\n---\ncuerpo nuevo\n")
        #expect(!model.isDirty)
        #expect(model.failure == nil)
        #expect(model.files.first { $0.id == "general" }?.title == "Nuevo nombre")
        // Atomic: no temp file left beside the templates.
        #expect(files() == FactoryTemplates.ids.map { "\($0).md" }.sorted())
    }

    @Test func aSecondSaveAfterTheFirstIsNotAConflict() throws {
        let model = model()
        model.select("general")
        model.text = "uno"
        model.save()
        model.text = "dos"

        model.save()

        #expect(model.failure == nil)
        #expect(try read(id: "general") == "dos")
    }

    @Test func aWriteFailureLeavesTheOriginalIntactAndKeepsTheEdit() throws {
        let model = model { _, _ in throw DiskFull() }
        model.select("general")
        let original = try read(id: "general")
        model.text = "editado"

        model.save()

        #expect(try read(id: "general") == original)
        #expect(model.failure == .writeFailed("disco lleno"))
        #expect(model.isDirty)
        #expect(model.text == "editado")
        #expect(!model.conflict)
    }

    @Test func aWriterThatFailsHalfwayStillLeavesTheFileUntouched() throws {
        // A writer that writes part of the data to a side file and then fails:
        // the template file itself must never be the one being written.
        let model = model { data, url in
            try data.prefix(3).write(to: url.deletingLastPathComponent().appendingPathComponent(".parcial"))
            throw DiskFull()
        }
        model.select("daily")
        let original = try read(id: "daily")
        model.text = "editado"

        model.save()

        #expect(try read(id: "daily") == original)
        #expect(model.failure == .writeFailed("disco lleno"))
    }

    @Test func aSuccessfulSaveClearsAnEarlierFailure() throws {
        let fail = FailSwitch(true)
        let model = model { data, url in
            if fail.isOn { throw DiskFull() }
            try data.write(to: url, options: .atomic)
        }
        model.select("general")
        model.text = "editado"
        model.save()
        #expect(model.failure != nil)

        fail.isOn = false
        model.save()

        #expect(model.failure == nil)
        #expect(try read(id: "general") == "editado")
    }

    // MARK: - mtime guard

    @Test func saveIsRefusedWhenTheFileChangedOnDiskSinceItWasLoaded() throws {
        let model = model()
        model.select("general")
        model.text = "mi edición"
        // Someone else rewrites the file after it was loaded.
        try write("cambio externo", id: "general")
        let url = TemplateStore.fileURL(id: "general", in: dir)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)

        model.save()

        #expect(try read(id: "general") == "cambio externo")
        #expect(model.conflict)
        #expect(model.failure == .changedOnDisk)
        #expect(model.text == "mi edición")
        #expect(model.isDirty)
    }

    @Test func reloadingAfterAConflictShowsTheDiskTextAndAllowsSavingAgain() throws {
        let model = model()
        model.select("general")
        model.text = "mi edición"
        try write("cambio externo", id: "general")
        let url = TemplateStore.fileURL(id: "general", in: dir)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        model.save()
        #expect(model.conflict)

        model.reloadFromDisk()

        #expect(!model.conflict)
        #expect(model.failure == nil)
        #expect(model.text == "cambio externo")
        #expect(!model.isDirty)

        model.text = "sobre el cambio externo"
        model.save()
        #expect(model.failure == nil)
        #expect(try read(id: "general") == "sobre el cambio externo")
    }

    @Test func aFileDeletedSinceItWasLoadedIsAConflictToo() throws {
        let model = model()
        model.select("daily")
        model.text = "editado"
        try fm.removeItem(at: TemplateStore.fileURL(id: "daily", in: dir))

        model.save()

        #expect(model.conflict)
        #expect(!fm.fileExists(atPath: TemplateStore.fileURL(id: "daily", in: dir).path))
    }

    @Test func revertKeepsTheConflictBecauseTheDiskStillDiffers() throws {
        let model = model()
        model.select("general")
        model.text = "mi edición"
        try write("cambio externo", id: "general")
        let url = TemplateStore.fileURL(id: "general", in: dir)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        model.save()

        model.revert()

        #expect(!model.isDirty)
        #expect(model.conflict)
    }

    // MARK: - Selection guard

    @Test func switchingWhileDirtyAsksAndKeepsTheEditUntilConfirmed() {
        let model = model()
        model.select("general")
        model.text = "editado"

        #expect(model.select("daily") == .needsConfirmation)
        #expect(model.selectedID == "general")
        #expect(model.text == "editado")
        #expect(model.pendingSelectionID == "daily")

        model.confirmPendingSelection()
        #expect(model.selectedID == "daily")
        #expect(model.text == FactoryTemplates.daily.fileContents)
        #expect(model.pendingSelectionID == nil)
        #expect(!model.isDirty)
    }

    @Test func cancellingTheSwitchKeepsTheEditAndTheSelection() {
        let model = model()
        model.select("general")
        model.text = "editado"
        model.select("daily")

        model.cancelPendingSelection()

        #expect(model.pendingSelectionID == nil)
        #expect(model.selectedID == "general")
        #expect(model.text == "editado")
        #expect(model.isDirty)
    }

    @Test func choosingTheOpenTemplateWhileDirtyNeverAsks() {
        let model = model()
        model.select("general")
        model.text = "editado"

        #expect(model.select("general") == .selected)
        #expect(model.text == "editado")
    }

    // MARK: - Refresh

    @Test func aFileAddedOutsideAppearsOnReloadWithoutLosingTheEditInProgress() throws {
        let model = model()
        model.select("general")
        model.text = "editado"
        try write("---\nnombre: Externa\n---\nx", id: "externa")

        model.reload()

        #expect(model.files.map(\.id).contains("externa"))
        #expect(model.selectedID == "general")
        #expect(model.text == "editado")
        #expect(model.isDirty)
    }

    // MARK: - Restore

    @Test func restoreBringsTheSelectedFactoryTemplateBackAndLeavesUserOnesAlone() throws {
        let custom = "---\nnombre: Cliente X\n---\npropia"
        try write(custom, id: "cliente-x")
        try write("editado", id: "general")
        let model = model()
        model.select("general")
        model.text = "y más edición sin guardar"

        model.restoreFactory()

        #expect(try read(id: "general") == FactoryTemplates.general.fileContents)
        #expect(model.text == FactoryTemplates.general.fileContents)
        #expect(!model.isDirty)
        #expect(model.failure == nil)
        #expect(try read(id: "cliente-x") == custom)
    }

    @Test func restoreOnAUserTemplateIsRefusedAndChangesNothing() throws {
        let custom = "---\nnombre: Cliente X\n---\npropia"
        try write(custom, id: "cliente-x")
        let model = model()
        model.select("cliente-x")
        model.text = "editado"

        model.restoreFactory()

        #expect(model.failure == .notFactory)
        #expect(try read(id: "cliente-x") == custom)
        #expect(model.text == "editado")
    }

    // MARK: - Unreadable files

    @Test func aFileThatIsNotUTF8IsEditableWithAWarningAndSavesAsValidUTF8() throws {
        var bytes = Data("---\nnombre: Vieja ".utf8)
        bytes.append(0xE9)
        bytes.append(Data("\n---\ncuerpo".utf8))
        try bytes.write(to: TemplateStore.fileURL(id: "vieja", in: dir))
        let model = model()

        model.select("vieja")
        #expect(model.hasInvalidBytes)
        #expect(model.text.contains("\u{FFFD}"))
        #expect(!model.isDirty)
        #expect(model.canSave)

        model.text = model.text.replacingOccurrences(of: "\u{FFFD}", with: "é")
        model.save()

        #expect(model.failure == nil)
        #expect(!model.hasInvalidBytes)
        #expect(try read(id: "vieja").contains("Vieja é"))
    }

    // MARK: - Backup of a lossy file

    private func writeInvalid(id: String) throws -> Data {
        var bytes = Data("---\nnombre: Vieja ".utf8)
        bytes.append(0xE9)
        bytes.append(Data("\n---\ncuerpo".utf8))
        try bytes.write(to: TemplateStore.fileURL(id: id, in: dir))
        return bytes
    }

    @Test func theFirstSaveOfAFileWithInvalidBytesKeepsTheOriginalBytesBesideIt() throws {
        let original = try writeInvalid(id: "vieja")
        let model = model()
        model.select("vieja")
        model.text += "\nmás"

        model.save()

        #expect(model.failure == nil)
        let name = try #require(model.backupName)
        #expect(name == "vieja.md.original-20260921-141320")
        #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == original)
        #expect(try read(id: "vieja").contains("más"))
        // Beside the template, but not a template: the listing ignores it.
        #expect(!model.files.contains { $0.id.contains("original") })
        #expect(!TemplateStore.files(in: dir).contains { $0.url.lastPathComponent == name })
    }

    @Test func aSecondSaveMakesNoSecondBackupAndAFreshLoadClearsTheName() throws {
        _ = try writeInvalid(id: "vieja")
        let model = model()
        model.select("vieja")
        model.save()
        let first = try #require(model.backupName)
        model.text += "x"

        model.save()

        #expect(model.backupName == first)
        #expect(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(".original-") }.count == 1)
        model.select("general")
        #expect(model.backupName == nil)
    }

    @Test func aCleanFileGetsNoBackup() throws {
        let model = model()
        model.select("general")
        model.text += "x"

        model.save()

        #expect(model.backupName == nil)
        #expect(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).allSatisfy { !$0.contains(".original-") })
    }

    @Test func ifTheBackupCannotBeWrittenTheSaveIsRefusedAndTheOriginalStays() throws {
        let original = try writeInvalid(id: "vieja")
        let model = model { _, _ in throw DiskFull() }
        model.select("vieja")
        model.text += "más"

        model.save()

        #expect(model.failure == .backupFailed("disco lleno"))
        #expect(try Data(contentsOf: TemplateStore.fileURL(id: "vieja", in: dir)) == original)
        #expect(model.backupName == nil)
        #expect(model.hasInvalidBytes)
    }

    @Test func twoBackupsInTheSameSecondDoNotOverwriteEachOther() throws {
        let first = try writeInvalid(id: "vieja")
        try Data("otra".utf8).write(to: dir.appendingPathComponent("vieja.md.original-20260921-141320"))
        let model = model()
        model.select("vieja")

        model.save()

        #expect(model.backupName == "vieja.md.original-20260921-141320-2")
        #expect(try Data(contentsOf: dir.appendingPathComponent("vieja.md.original-20260921-141320-2")) == first)
        #expect(try read(id: "vieja").isEmpty == false)
        #expect(try String(contentsOf: dir.appendingPathComponent("vieja.md.original-20260921-141320"), encoding: .utf8) == "otra")
    }

    @Test(.enabled(if: geteuid() != 0, "root ignores file permissions"))
    func aFileThatCannotBeReadIsListedButNotSavedOver() throws {
        try write("---\nnombre: Cerrada\n---\nx", id: "cerrada")
        let url = TemplateStore.fileURL(id: "cerrada", in: dir)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let model = model()

        model.select("cerrada")
        #expect(model.files.map(\.id).contains("cerrada"))
        #expect(model.readError != nil)
        #expect(!model.canSave)

        model.text = "reemplazo"
        model.save()

        #expect(model.failure == .notEditable)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try read(id: "cerrada") == "---\nnombre: Cerrada\n---\nx")
    }

    // MARK: - New template

    @Test func aNewTemplateIsCreatedWithASkeletonListedAndSelected() throws {
        let model = model()

        #expect(model.create(id: "  cliente-nuevo  "))

        #expect(model.selectedID == "cliente-nuevo")
        #expect(model.files.map(\.id).contains("cliente-nuevo"))
        let template = try #require(TemplateStore.template(id: "cliente-nuevo", in: dir))
        #expect(template.nombre == "cliente-nuevo")
        #expect(model.text == (try read(id: "cliente-nuevo")))
        #expect(!model.isDirty)
        #expect(!model.isFactory)
        #expect(model.failure == nil)
    }

    @Test func anInvalidIDCreatesNothing() {
        let model = model()
        let before = files()

        for bad in ["", "   ", "a/b", ".oculta", "../fuera"] {
            #expect(!model.create(id: bad), "\(bad)")
            #expect(model.failure == .invalidID, "\(bad)")
        }
        #expect(files() == before)
        #expect(!fm.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("fuera.md").path))
    }

    @Test func anExistingIDIsNeverOverwritten() throws {
        let model = model()
        let original = try read(id: "general")

        #expect(!model.create(id: "general"))

        #expect(model.failure == .exists)
        #expect(try read(id: "general") == original)
    }

    @Test func aFailedWriteWhileCreatingLeavesNoFile() {
        let model = model { _, _ in throw DiskFull() }
        let before = files()

        #expect(!model.create(id: "nueva"))

        #expect(model.failure == .writeFailed("disco lleno"))
        #expect(files() == before)
        #expect(model.selectedID == nil)
    }

    @Test func creatingWhileTheOpenTemplateIsDirtyIsRefusedBeforeWritingAnything() {
        let model = model()
        model.select("general")
        model.text = "editado"
        let before = files()

        #expect(!model.create(id: "nueva"))

        #expect(model.failure == .unsavedChanges)
        #expect(files() == before)
        #expect(model.selectedID == "general")
        #expect(model.pendingSelectionID == nil)
        #expect(model.text == "editado")
    }

    @Test func aNewIDMayNotContainWhitespaceButExistingFilesKeepTheirs() throws {
        try write("---\nnombre: Con espacio\n---\nx", id: "con espacio")
        let model = model()

        for bad in ["a b", "a\tb", "a\nb"] {
            #expect(!model.create(id: bad), "\(bad.debugDescription)")
            #expect(model.failure == .invalidID)
        }
        #expect(!files().contains("a b.md"))
        // An existing file with a space is still listed, opened and saved.
        model.select("con espacio")
        #expect(model.selectedID == "con espacio")
        model.text += "y"
        model.save()
        #expect(model.failure == nil)
        #expect(try read(id: "con espacio").hasSuffix("y"))
    }

    @Test func clearingTheFailureForgetsOnlyTheFailure() throws {
        let model = model()
        model.select("general")
        #expect(!model.create(id: "a/b"))
        #expect(model.failure == .invalidID)

        model.clearFailure()

        #expect(model.failure == nil)
        #expect(model.selectedID == "general")
    }

    // MARK: - Draft name (quit warning)

    @Test func theDraftNameIsTheOpenTemplatesTitleOnlyWhileItHasUnsavedChanges() {
        let model = model()
        #expect(model.draftName == nil)
        model.select("general")
        #expect(model.draftName == nil)

        model.text += "x"
        #expect(model.draftName == "Minuta general")

        model.save()
        #expect(model.draftName == nil)
    }

    // MARK: - Templates changed notification

    @Test func everySuccessfulWriteAnnouncesTheChange() {
        nonisolated(unsafe) var posts = 0
        let token = center.addObserver(forName: .meetingVoxTemplatesDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { center.removeObserver(token) }
        let model = model()
        model.select("general")

        model.text += "x"
        model.save()
        #expect(posts == 1)

        #expect(model.create(id: "nueva"))
        #expect(posts == 2)

        model.select("general")
        model.restoreFactory()
        #expect(posts == 3)
    }

    @Test func aFailedWriteAnnouncesNothing() {
        nonisolated(unsafe) var posts = 0
        let token = center.addObserver(forName: .meetingVoxTemplatesDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { center.removeObserver(token) }
        let model = model { _, _ in throw DiskFull() }
        model.select("general")
        model.text += "x"

        model.save()
        _ = model.create(id: "nueva")
        _ = model.create(id: "a/b")

        #expect(posts == 0)
    }
}

/// A flag the injected writer reads and the test flips, safe to capture in a
/// `@Sendable` closure (a captured `var` would warn).
private final class FailSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
