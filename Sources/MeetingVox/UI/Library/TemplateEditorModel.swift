import Foundation
import Observation

extension Notification.Name {
    /// Posted (main thread) after the editor wrote a template file (save,
    /// create, restore), so the main window's snapshot of the templates
    /// (type labels, the generate pickers) refreshes.
    static let meetingVoxTemplatesDidChange = AppIdentity.notificationName("templatesDidChange")
}

/// The Plantillas editor's state (LE-1..LE-3): the folder's files, the one
/// open as raw markdown, and the operations on it — save, revert, restore a
/// factory template, create one.
///
/// Every dependency is explicit: the folder is `dir`, the writer is a seam
/// (default: atomic), and the file dates come from a seam too, so tests and
/// the headless snapshots run it over a temp folder and can inject a failing
/// disk. It touches no defaults from `Config`.
///
/// Saving is guarded twice. A write error leaves the original file as it was
/// (the default writer is atomic: temp file, then rename) and keeps the edit
/// in memory. And if the file's date is not the one it had when it was loaded
/// (someone else edited it, or deleted it), the save is refused with
/// `changedOnDisk` and the user reloads (`reloadFromDisk`) before saving.
@MainActor
@Observable
final class TemplateEditorModel {
    /// What the last operation could not do. `nil` = fine.
    enum Failure: Equatable {
        case changedOnDisk
        case writeFailed(String)
        case invalidID
        case exists
        /// Could not be read at all, so saving would replace unknown content.
        case notEditable
        case notFactory
        case restoreFailed(String)
        /// The file had invalid bytes and the copy of the original could not
        /// be written, so nothing was saved.
        case backupFailed(String)
        /// A new template was asked for while the open one has unsaved changes.
        case unsavedChanges
    }

    enum SelectOutcome: Equatable {
        case selected
        /// The open template has unsaved changes: `pendingSelectionID` holds
        /// the one asked for until `confirmPendingSelection` / `cancelPendingSelection`.
        case needsConfirmation
    }

    let dir: URL
    private(set) var files: [TemplateStore.TemplateFile] = []
    private(set) var selectedID: String?
    /// The editor's text (bound to the text view).
    var text = ""
    private(set) var savedText = ""
    /// The open file had bytes that are not UTF-8; saving replaces them.
    private(set) var hasInvalidBytes = false
    private(set) var readError: String?
    /// Save was refused because the disk changed; offer "Recargar".
    private(set) var conflict = false
    private(set) var failure: Failure?
    private(set) var pendingSelectionID: String?
    /// File name of the copy of the original bytes made by the last save of
    /// a file that had invalid bytes (next to the template, not listed).
    private(set) var backupName: String?

    @ObservationIgnored private let writer: @Sendable (Data, URL) throws -> Void
    @ObservationIgnored private let modified: @Sendable (URL) -> Date?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let notifications: NotificationCenter
    /// The file's date when it was loaded or last saved.
    @ObservationIgnored private var loadedModified: Date?

    init(
        dir: URL,
        write: @escaping @Sendable (Data, URL) throws -> Void = TemplateEditorModel.atomicWrite,
        modified: @escaping @Sendable (URL) -> Date? = TemplateStore.modificationDate(of:),
        now: @escaping @Sendable () -> Date = { Date() },
        notifications: NotificationCenter = .default
    ) {
        self.dir = dir
        self.writer = write
        self.modified = modified
        self.now = now
        self.notifications = notifications
    }

    /// Temp file plus rename: a failure midway never leaves half a template.
    nonisolated static func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Derived

    var isDirty: Bool { selectedID != nil && text != savedText }
    /// A file with invalid bytes can be saved as it stands: that is how the
    /// user replaces them.
    var canSave: Bool { selectedID != nil && readError == nil && (isDirty || hasInvalidBytes) }
    var isFactory: Bool { selectedID.map(TemplateStore.isFactoryID) ?? false }

    /// The open template's name while it has unsaved changes (the quit
    /// warning names it); nil otherwise.
    var draftName: String? {
        guard isDirty, let id = selectedID else { return nil }
        return files.first { $0.id == id }?.title ?? id
    }

    /// Forget the last failure (a sheet that shows it opens or closes).
    func clearFailure() { failure = nil }

    // MARK: - Loading

    /// Re-list the folder. The open template keeps its text and dirty state;
    /// only the list (new files, changed names) is refreshed.
    func reload() {
        files = TemplateStore.files(in: dir)
    }

    /// Show `id` (nil = none). With unsaved changes it asks first.
    @discardableResult
    func select(_ id: String?) -> SelectOutcome {
        switch EditorGuard.decide(isDirty: isDirty, current: selectedID, target: id) {
        case .confirmDiscard:
            pendingSelectionID = id
            return .needsConfirmation
        case .proceed:
            pendingSelectionID = nil
            if id != selectedID || id == nil { load(id) }
            return .selected
        }
    }

    func confirmPendingSelection() {
        guard let id = pendingSelectionID else { return }
        pendingSelectionID = nil
        load(id)
    }

    func cancelPendingSelection() { pendingSelectionID = nil }

    /// "Recargar": drop the edit and take whatever the disk has now.
    func reloadFromDisk() {
        reload()
        load(selectedID)
    }

    private func load(_ id: String?) {
        conflict = false
        failure = nil
        backupName = nil
        guard let id, let file = TemplateStore.file(id: id, in: dir) else {
            selectedID = nil
            text = ""
            savedText = ""
            hasInvalidBytes = false
            readError = nil
            loadedModified = nil
            reload()
            return
        }
        selectedID = id
        text = file.text
        savedText = file.text
        hasInvalidBytes = file.lossy
        readError = file.readError
        loadedModified = file.modified
        reload()
    }

    // MARK: - Editing

    /// Back to the last saved text.
    func revert() {
        text = savedText
        failure = nil
    }

    func save() {
        guard let id = selectedID else { return }
        guard readError == nil else { return fail(.notEditable) }
        guard TemplateStore.isValidID(id) else { return fail(.invalidID) }
        let url = TemplateStore.fileURL(id: id, in: dir)
        guard modified(url) == loadedModified else {
            conflict = true
            return fail(.changedOnDisk)
        }
        // The first save of a file with invalid bytes replaces them for
        // good, so the original bytes are kept beside it first.
        var backup: String?
        if hasInvalidBytes {
            do {
                backup = try makeBackup(of: url)
            } catch {
                return fail(.backupFailed(error.localizedDescription))
            }
        }
        do {
            try writer(Data(text.utf8), url)
        } catch {
            return fail(.writeFailed(error.localizedDescription))
        }
        savedText = text
        hasInvalidBytes = false
        loadedModified = modified(url)
        failure = nil
        if let backup { backupName = backup }
        reload()
        announceChange()
    }

    /// `<id>.md.original-yyyyMMdd-HHmmss` (UTC; `-2`, `-3`… if taken) next to
    /// the file. Its extension is not `md`, so `TemplateStore.files` never
    /// lists it as a template.
    private func makeBackup(of url: URL) throws -> String {
        let original = try Data(contentsOf: url)
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now())
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        let base = url.lastPathComponent + ".original-" + stamp
        var name = base
        var attempt = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            attempt += 1
            name = base + "-\(attempt)"
        }
        try writer(original, dir.appendingPathComponent(name))
        return name
    }

    private func announceChange() {
        notifications.post(name: .meetingVoxTemplatesDidChange, object: nil)
    }

    /// Put the selected factory template back to its shipped content. The
    /// caller confirms first; this drops any unsaved edit of it.
    func restoreFactory() {
        guard let id = selectedID, TemplateStore.isFactoryID(id) else { return fail(.notFactory) }
        do {
            try TemplateStore.restoreFactoryTemplate(id: id, in: dir)
        } catch {
            return fail(.restoreFailed(error.localizedDescription))
        }
        load(id)
        announceChange()
    }

    /// A new id may not contain whitespace (it becomes a file name people type
    /// and script). Existing files keep whatever they have (`isValidID` only).
    static func isValidNewID(_ id: String) -> Bool {
        TemplateStore.isValidID(id) && id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    /// A new template `<id>.md` with a skeleton, listed and opened. `false`
    /// (and `failure`) when the open template has unsaved changes, the id is
    /// not valid for a new template, it already exists, or it cannot be
    /// written. Refusing while dirty happens before anything is written, so
    /// the new file never appears behind a "discard changes?" question.
    @discardableResult
    func create(id rawID: String) -> Bool {
        guard !isDirty else { fail(.unsavedChanges); return false }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidNewID(id) else { fail(.invalidID); return false }
        let url = TemplateStore.fileURL(id: id, in: dir)
        guard !FileManager.default.fileExists(atPath: url.path) else { fail(.exists); return false }
        let skeleton = MinutesTemplate(id: id, nombre: id, descripcion: "", cuerpo: MinutesPrompts.plantillaNueva)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writer(Data(skeleton.fileContents.utf8), url)
        } catch {
            fail(.writeFailed(error.localizedDescription))
            return false
        }
        failure = nil
        reload()
        select(id)
        announceChange()
        return true
    }

    private func fail(_ failure: Failure) { self.failure = failure }
}
