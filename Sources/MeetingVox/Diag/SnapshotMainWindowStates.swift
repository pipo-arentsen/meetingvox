import SwiftUI

/// The main window's snapshot states (shell, sidebar, list, bulk,
/// Tareas). The full-window states use `flatColumns`: an offscreen
/// `NavigationSplitView` cannot draw its sidebar column, so the same three
/// column views are laid out with plain stacks at the same widths. The
/// sidebar and the list are also rendered on their own.
enum SnapshotMainWindowStates {
    static let windowSize = MainLayout.defaultSize

    @MainActor
    static var all: [SnapshotState] {
        [window, windowSingle, windowRecording, windowBulk, windowPersonal, windowEmpty, windowTareas, windowTareasFiltered, windowTareasEmpty, windowSplitTareas, windowSplitGlosario, sidebar, list, listSearchSnippet, pills]
    }

    // MARK: - Builders

    /// A model over the fixture root, scanned, after `configure`.
    @MainActor
    private static func model(
        _ context: SnapshotContext, store: PipelineStatusStore = PipelineStatusStore(),
        configure: (MainWindowModel, SnapshotFixtures.Installed) -> Void = { _, _ in }
    ) -> MainWindowModel {
        let model = context.env.makeMainWindowModel(store: store)
        SnapshotEnvironment.load(model)
        configure(model, context.installed)
        return model
    }

    /// The entry of a fixture kind as the scan reported it.
    @MainActor
    private static func dir(_ kind: SnapshotFixtures.Kind, _ model: MainWindowModel, _ installed: SnapshotFixtures.Installed) -> URL? {
        guard let fixture = installed.dirs(of: kind).first else { return nil }
        return model.meetings.entries.first { $0.dir.standardizedFileURL == fixture.standardizedFileURL }?.dir
    }

    @MainActor
    private static func fullWindow(_ model: MainWindowModel) -> AnyView {
        AnyView(MainView(model: model, onToggleRecording: {}, flatColumns: true))
    }

    @MainActor
    private static func splitWindow(_ model: MainWindowModel) -> AnyView {
        AnyView(MainView(model: model, onToggleRecording: {}, flatColumns: false))
    }

    // MARK: - States

    /// Nothing selected; the transcription of the newest session is still
    /// owed (its markers say so), and the summary of another is running.
    @MainActor
    static let window = SnapshotState(name: "main-window", width: windowSize.width, height: windowSize.height) { context in
        let store = PipelineStatusStore()
        let model = model(context, store: store)
        if let folder = context.installed.dirs(of: .inProgress).first?.lastPathComponent {
            store.apply(.running(.minutes, folder: folder, queued: 0))
        }
        return fullWindow(model)
    }

    /// One row selected: the detail column's stand-in until the session detail.
    @MainActor
    static let windowSingle = SnapshotState(name: "main-window-single", width: windowSize.width, height: windowSize.height) { context in
        fullWindow(model(context) { model, installed in
            if let dir = dir(.complete, model, installed) { model.meetings.selection = [dir] }
        })
    }

    /// Recording in progress: "Detener 12:34" and the recording pill.
    @MainActor
    static let windowRecording = SnapshotState(name: "main-window-recording", width: windowSize.width, height: windowSize.height) { context in
        let store = PipelineStatusStore()
        let model = model(context, store: store)
        if let recording = dir(.inProgress, model, context.installed) {
            store.apply(.recording(recording, elapsed: 754))
        }
        return fullWindow(model)
    }

    /// Three rows selected: the bulk panel.
    @MainActor
    static let windowBulk = SnapshotState(name: "main-window-bulk", width: windowSize.width, height: windowSize.height) { context in
        fullWindow(model(context) { model, installed in
            model.meetings.selection = Set(installed.bulkSelection.compactMap { fixture in
                model.meetings.entries.first { $0.dir.standardizedFileURL == fixture.standardizedFileURL }?.dir
            })
        })
    }

    /// The Personal ámbito selected in the sidebar.
    @MainActor
    static let windowPersonal = SnapshotState(name: "main-window-personal", width: windowSize.width, height: windowSize.height) { context in
        fullWindow(model(context) { model, _ in model.sidebar = .ambito(.personal) })
    }

    /// A recordings root with no sessions at all.
    @MainActor
    static let windowEmpty = SnapshotState(name: "main-window-empty", width: windowSize.width, height: windowSize.height) { context in
        let empty = context.env.tempRoot.appendingPathComponent("EmptyRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let model = context.env.makeMainWindowModel(root: empty)
        SnapshotEnvironment.load(model)
        return fullWindow(model)
    }

    /// Tareas: every task of the fixture sessions, newest meeting first, with
    /// the hint about summaries that were never extracted.
    @MainActor
    static let windowTareas = SnapshotState(name: "main-window-tareas", width: windowSize.width, height: windowSize.height) { context in
        fullWindow(model(context) { model, _ in model.sidebar = .tareas })
    }

    /// Tareas narrowed to one owner ("Yo") and a search word.
    @MainActor
    static let windowTareasFiltered = SnapshotState(name: "main-window-tareas-filtered", width: windowSize.width, height: windowSize.height) { context in
        fullWindow(model(context) { model, _ in
            model.sidebar = .tareas
            model.tasks.who = .person("Yo")
            model.tasks.query = "semana"
        })
    }

    /// Tareas over a recordings root with no sessions: the empty state.
    @MainActor
    static let windowTareasEmpty = SnapshotState(name: "main-window-tareas-empty", width: windowSize.width, height: windowSize.height) { context in
        let empty = context.env.tempRoot.appendingPathComponent("EmptyRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let model = context.env.makeMainWindowModel(root: empty)
        SnapshotEnvironment.load(model)
        model.sidebar = .tareas
        return fullWindow(model)
    }

    /// The REAL `NavigationSplitView` path (`flatColumns: false`) on Tareas:
    /// the strip and the content/detail columns must draw (the sidebar column
    /// is a hole offscreen). The flat states never caught the blank window
    /// the columns' minimum-size measuring caused.
    @MainActor
    static let windowSplitTareas = SnapshotState(name: "main-window-split-tareas", width: windowSize.width, height: windowSize.height) { context in
        splitWindow(model(context) { model, _ in model.sidebar = .tareas })
    }

    /// The real split view on Glosario.
    @MainActor
    static let windowSplitGlosario = SnapshotState(name: "main-window-split-glosario", width: windowSize.width, height: windowSize.height) { context in
        splitWindow(model(context) { model, _ in model.sidebar = .glosario })
    }

    /// The sidebar on its own (also because a split view's sidebar column is
    /// a hole offscreen).
    @MainActor
    static let sidebar = SnapshotState(name: "sidebar", width: MainLayout.sidebarWidth, height: windowSize.height) { context in
        AnyView(SidebarView(model: model(context) { model, _ in model.sidebar = .reuniones }))
    }

    /// The list column on its own.
    @MainActor
    static let list = SnapshotState(name: "meeting-list", width: MainLayout.listWidth, height: windowSize.height) { context in
        AnyView(MeetingListView(model: model(context)))
    }

    /// A search whose words appear only in transcripts and minutes: each row
    /// shows the line it matched, the query's words marked.
    @MainActor
    static let listSearchSnippet = SnapshotState(
        name: "meeting-list-search-snippet", width: MainLayout.listWidth, height: windowSize.height
    ) { context in
        AnyView(MeetingListView(model: model(context) { model, _ in
            SnapshotEnvironment.search(model, "accesos ambiente")
        }))
    }

    /// Every status chip the rows can show.
    @MainActor
    static let pills = SnapshotState(name: "status-pills", width: 900, height: nil) { _ in
        let all: [StatusPill] = [
            .recording, .error, .active(.transcription), .active(.minutes), .active(.summary), .sending, .pending, .sent,
        ]
        return AnyView(
            HStack(spacing: 8) { ForEach(all, id: \.label) { StatusPillView(pill: $0) } }
                .padding(16)
        )
    }
}
