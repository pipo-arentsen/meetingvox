import Foundation

/// Filesystem access for minutes templates. Every function takes the
/// directory explicitly so tests can point it at a temp dir; production code
/// passes `Config.templatesDir`. Stateless, so no isolation is needed.
enum TemplateStore {
    static let fileExtension = "md"

    // MARK: - Factory templates

    /// Create `dir` and write the factory templates that are missing. Never
    /// overwrites: once a file exists it belongs to the user, even if it is
    /// an untouched copy of the factory version.
    static func installFactoryTemplatesIfMissing(in dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for template in FactoryTemplates.all {
            let url = fileURL(id: template.id, in: dir)
            guard !fm.fileExists(atPath: url.path) else { continue }
            try write(template, to: url)
        }
    }

    enum RestoreError: Error, Equatable {
        /// Only the shipped templates can be restored; anything else is the
        /// user's and is never rewritten by a "restore".
        case notFactory(String)
    }

    /// Whether `id` is one of the shipped templates. Ids are file stems, so
    /// the comparison is exact (case included).
    static func isFactoryID(_ id: String) -> Bool {
        FactoryTemplates.ids.contains(id)
    }

    /// Reset ONE factory template to its shipped content (creating the folder
    /// or the file if either is gone). Refuses any other id, so a user
    /// template can never be replaced by a "restore".
    static func restoreFactoryTemplate(id: String, in dir: URL) throws {
        guard isValidID(id), let template = FactoryTemplates.all.first(where: { $0.id == id }) else {
            throw RestoreError.notFactory(id)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(template, to: fileURL(id: id, in: dir))
    }

    // MARK: - Reading

    /// One `*.md` file as the Biblioteca editor sees it: never dropped for
    /// being unreadable, so the user can still open and fix it.
    struct TemplateFile: Equatable, Sendable {
        let id: String
        let url: URL
        /// The file's text. Bytes that are not valid UTF-8 are replaced with
        /// U+FFFD (`lossy`), so saving such a file replaces them for good.
        let text: String
        /// Parsed from `text`; nil only when the file could not be read at all.
        let template: MinutesTemplate?
        let lossy: Bool
        /// The system's reason when the file could not be read (permissions,
        /// I/O); `text` is then empty and the editor must not save over it.
        let readError: String?
        /// Modification date when read: the editor's "changed on disk" guard.
        let modified: Date?

        var title: String { template?.nombre ?? id }
    }

    /// Every `*.md` in `dir` (hidden files skipped), sorted by display name,
    /// including the ones `list(in:)` skips for not being UTF-8.
    static func files(in dir: URL) -> [TemplateFile] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch {
            log("could not list templates in \(dir.path): \(error)")
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .map(readFile)
            .sorted { isOrdered(($0.title, $0.id), before: ($1.title, $1.id)) }
    }

    /// The file stored as `<id>.md`, or nil if missing or the id is invalid.
    static func file(id: String, in dir: URL) -> TemplateFile? {
        guard isValidID(id) else { return nil }
        let url = fileURL(id: id, in: dir)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return readFile(url)
    }

    /// The file's modification date, nil if it does not exist.
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Every `*.md` in `dir`, sorted by display name. Unreadable files are
    /// logged and skipped so one bad file never hides the rest.
    static func list(in dir: URL) -> [MinutesTemplate] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch {
            log("could not list templates in \(dir.path): \(error)")
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .compactMap(load)
            .sorted { isOrdered(($0.nombre, $0.id), before: ($1.nombre, $1.id)) }
    }

    /// The template stored as `<id>.md`, or nil if missing, unreadable or
    /// the id is invalid (see `isValidID`).
    static func template(id: String, in dir: URL) -> MinutesTemplate? {
        guard isValidID(id) else { return nil }
        let url = fileURL(id: id, in: dir)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return load(url)
    }

    /// A template id is a plain file-name stem: not empty, no `/` and no
    /// leading `.`. Ids come from config and the menu and end up in paths
    /// (`<id>.md`, `minuta.<id>.md`), so anything else could read or write
    /// outside the templates or session folder.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.hasPrefix(".")
    }

    // MARK: - Helpers

    static func fileURL(id: String, in dir: URL) -> URL {
        dir.appendingPathComponent(id).appendingPathExtension(fileExtension)
    }

    /// Display-name order, tie-broken on id so it is deterministic.
    private static func isOrdered(_ lhs: (name: String, id: String), before rhs: (name: String, id: String)) -> Bool {
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.id < rhs.id
        }
    }

    private static func readFile(_ url: URL) -> TemplateFile {
        let id = url.deletingPathExtension().lastPathComponent
        let modified = modificationDate(of: url)
        do {
            let data = try Data(contentsOf: url)
            let strict = String(data: data, encoding: .utf8)
            let text = strict ?? String(decoding: data, as: UTF8.self)
            return TemplateFile(
                id: id, url: url, text: text, template: MinutesTemplate.parse(id: id, contents: text),
                lossy: strict == nil, readError: nil, modified: modified
            )
        } catch {
            log("could not read template \(url.path): \(error)")
            return TemplateFile(
                id: id, url: url, text: "", template: nil, lossy: false,
                readError: error.localizedDescription, modified: modified
            )
        }
    }

    private static func load(_ url: URL) -> MinutesTemplate? {
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let id = url.deletingPathExtension().lastPathComponent
            return MinutesTemplate.parse(id: id, contents: contents)
        } catch {
            log("skipping unreadable template \(url.path): \(error)")
            return nil
        }
    }

    private static func write(_ template: MinutesTemplate, to url: URL) throws {
        try Data(template.fileContents.utf8).write(to: url, options: .atomic)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }
}
