import Foundation

/// The status-bar menu as data (one level, no session submenus). Pure:
/// `MenuBarController` renders the entries and dispatches the commands, so
/// the order, shortcuts and conditions are tested without an `NSMenu`.
///
/// Rule (user requirement): the recording toggle is always the first
/// action, whatever the state; status and processing lines are information,
/// never actions.
enum MenuModel {
    /// A recording in progress: the elapsed text and, when the meeting
    /// prompt started it, the app's short name.
    struct Recording: Equatable {
        var elapsed: String
        var app: String?
    }

    /// The newest session, for "Última: <title>".
    struct Last: Equatable {
        var dir: URL
        var title: String
        var hasMinutes: Bool
    }

    struct Input: Equatable {
        var recording: Recording?
        /// Minutes enabled: only then "Plantilla ▸" is offered (while recording).
        var offersTemplate = false
        /// Already formatted processing lines; nil = nothing running/failed.
        var transcription: String?
        var minutes: String?
        var summary: String?
        /// Hindsight export paused on a rejected token.
        var tokenInvalid = false
        var last: Last?
    }

    enum Command: Equatable {
        /// Information line, not clickable.
        case info
        case toggleRecording
        case template
        case openLast(URL, hasMinutes: Bool)
        case openMainWindow
        case rebuildIndex
        case openFolder
        case settings
        case onboarding
        case quit
    }

    struct Shortcut: Equatable {
        var key: String
        /// ⌘⌥ instead of ⌘.
        var option: Bool
    }

    struct Item: Equatable {
        var command: Command
        var title: String
        var shortcut: Shortcut?
        var isEnabled: Bool
        /// Shown in place of the previous item while ⌥ is held.
        var isAlternate: Bool
        var hasSubmenu: Bool
    }

    enum Entry: Equatable {
        case separator
        case item(Item)
    }

    static func build(_ input: Input) -> [Entry] {
        var entries: [Entry] = []
        func add(
            _ command: Command, _ title: String, key: String? = nil, option: Bool = false,
            enabled: Bool = true, alternate: Bool = false, submenu: Bool = false
        ) {
            entries.append(.item(Item(
                command: command, title: title,
                shortcut: key.map { Shortcut(key: $0, option: option) },
                isEnabled: enabled, isAlternate: alternate, hasSubmenu: submenu
            )))
        }

        let recording = input.recording
        add(.info, recording.map { Textos.Menu.grabando($0.elapsed, app: $0.app) } ?? Textos.Menu.inactivo, enabled: false)
        add(
            .toggleRecording,
            recording == nil ? Textos.Menu.iniciarGrabacion : Textos.Menu.detenerGrabacion, key: "r"
        )
        if recording != nil, input.offersTemplate {
            add(.template, Textos.Menu.plantillaMinuta, submenu: true)
        }

        let lines = [input.transcription, input.minutes, input.summary].compactMap { $0 }
            + (input.tokenInvalid ? [Textos.Memoria.tokenInvalido] : [])
        if !lines.isEmpty {
            entries.append(.separator)
            for line in lines { add(.info, line, enabled: false) }
        }

        entries.append(.separator)
        if let last = input.last {
            add(.openLast(last.dir, hasMinutes: last.hasMinutes), Textos.Menu.ultima(last.title))
        }
        add(.openMainWindow, Textos.Menu.abrirVentana, key: "j")
        add(.rebuildIndex, Textos.Sesiones.reconstruirIndice, key: "j", option: true, alternate: true)
        add(.openFolder, Textos.Menu.abrirCarpeta, key: "o")

        entries.append(.separator)
        add(.settings, Textos.Menu.configuracion, key: ",")
        add(.onboarding, Textos.Menu.primerosPasos)

        entries.append(.separator)
        add(.quit, Textos.Menu.salir, key: "q")
        return entries
    }

    static func items(of entries: [Entry]) -> [Item] {
        entries.compactMap { if case .item(let item) = $0 { item } else { nil } }
    }

    /// The entries without their titles: two menus with the same shape can
    /// be updated in place (the elapsed time ticking) instead of rebuilt,
    /// which would disturb a menu that is open.
    static func shape(_ entries: [Entry]) -> [Entry] {
        entries.map {
            guard case .item(var item) = $0 else { return $0 }
            item.title = ""
            return .item(item)
        }
    }

    /// The newest session folder, read from disk when the menu opens. Cheap
    /// on purpose, since it runs on the main thread: one directory listing
    /// (names only), then `meta.json` is checked newest-first only until the
    /// first folder that has one; title and minutes are read for that folder
    /// alone. Cost does not grow with the recordings history. `exists` is the
    /// seam that counts those checks in tests.
    static func last(
        in root: URL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Last? {
        for dir in SessionFiles.candidateFolders(in: root)
        where exists(dir.appendingPathComponent(SessionFiles.meta)) {
            return Last(
                dir: dir, title: SessionLabel.load(dir),
                hasMinutes: SessionFiles.exists(SessionFiles.minutes, in: dir)
            )
        }
        return nil
    }
}
