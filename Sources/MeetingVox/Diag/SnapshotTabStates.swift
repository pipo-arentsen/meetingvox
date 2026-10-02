import SwiftUI

/// The detail tabs' snapshot states: Resumen, Minuta (rendered
/// document with its tasks table, retry bar after an error, template picker
/// when there are no minutes, progress bar while a job runs) and
/// Transcripción (fixture and a long list). Full-window states use
/// `flatColumns` like the earlier units.
enum SnapshotTabStates {
    static let windowSize = MainLayout.defaultSize

    @MainActor
    static var all: [SnapshotState] {
        [resumen, resumenGenerating, resumenTasksNotExtracted, resumenNoTasks, minuta, minutaError, minutaGenerate, minutaRunning, transcripcion, transcripcionLong, transcripcionGlossary] + SnapshotPlaybackStates.all
    }

    /// The fixture session of `kind` selected on `tab`, its detail data read.
    @MainActor
    private static func view(
        _ context: SnapshotContext, _ kind: SnapshotFixtures.Kind, tab: DetailTab,
        live: (PipelineStatusStore, String) -> Void = { _, _ in }
    ) -> AnyView {
        let store = PipelineStatusStore()
        let model = context.env.makeMainWindowModel(store: store)
        SnapshotEnvironment.load(model)
        model.tab = tab
        if let fixture = context.installed.dirs(of: kind).first,
           let entry = model.meetings.entries.first(where: { $0.dir.standardizedFileURL == fixture.standardizedFileURL }) {
            model.meetings.selection = [entry.dir]
            live(store, entry.dir.lastPathComponent)
            SnapshotEnvironment.loadDetail(model)
        }
        return AnyView(MainView(model: model, onToggleRecording: {}, flatColumns: true))
    }

    @MainActor
    static let resumen = SnapshotState(name: "tab-resumen", width: windowSize.width, height: windowSize.height) {
        view($0, .complete, tab: .resumen)
    }

    /// Summary still owed: the tab says so.
    @MainActor
    static let resumenGenerating = SnapshotState(name: "tab-resumen-generating", width: windowSize.width, height: windowSize.height) {
        view($0, .inProgress, tab: .resumen)
    }

    /// A summary from before task extraction: the tasks column says they were
    /// never extracted (not "none").
    @MainActor
    static let resumenTasksNotExtracted = SnapshotState(
        name: "tab-resumen-tasks-not-extracted", width: windowSize.width, height: windowSize.height
    ) {
        view($0, .minutesError, tab: .resumen)
    }

    /// Extracted, and the meeting had no tasks.
    @MainActor
    static let resumenNoTasks = SnapshotState(name: "tab-resumen-no-tasks", width: windowSize.width, height: windowSize.height) {
        view($0, .noMinutes, tab: .resumen)
    }

    /// `minuta.md` rendered, with its tasks table.
    @MainActor
    static let minuta = SnapshotState(name: "tab-minuta", width: windowSize.width, height: windowSize.height) {
        view($0, .complete, tab: .minuta)
    }

    /// `minuta.error` and no minutes: the "Reintentar" bar, no "Generar".
    @MainActor
    static let minutaError = SnapshotState(name: "tab-minuta-error", width: windowSize.width, height: windowSize.height) {
        view($0, .minutesError, tab: .minuta)
    }

    /// Transcript and no minutes: the template picker and "Generar minuta".
    @MainActor
    static let minutaGenerate = SnapshotState(name: "tab-minuta-generate", width: windowSize.width, height: windowSize.height) {
        view($0, .noMinutes, tab: .minuta)
    }

    /// A minutes job running for a session that owes them.
    @MainActor
    static let minutaRunning = SnapshotState(name: "tab-minuta-running", width: windowSize.width, height: windowSize.height) {
        view($0, .inProgress, tab: .minuta) { store, folder in
            store.apply(.running(.minutes, folder: folder, queued: 0))
        }
    }

    @MainActor
    static let transcripcion = SnapshotState(name: "tab-transcripcion", width: windowSize.width, height: windowSize.height) {
        view($0, .complete, tab: .transcripcion)
    }

    /// A 50-minute meeting in a recordings folder of its own.
    @MainActor
    static let transcripcionLong = SnapshotState(name: "tab-transcripcion-long", width: windowSize.width, height: windowSize.height) { context in
        let root = context.env.tempRoot.appendingPathComponent("LongRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try? SnapshotFixtures.installLongSession(in: root, env: context.env)
        let model = context.env.makeMainWindowModel(root: root)
        SnapshotEnvironment.load(model)
        model.tab = .transcripcion
        if let entry = model.meetings.entries.first {
            model.meetings.selection = [entry.dir]
            SnapshotEnvironment.loadDetail(model)
        }
        return AnyView(MainView(model: model, onToggleRecording: {}, flatColumns: true))
    }
}

extension SnapshotTabStates {
    /// The glossary's corrections in the transcript: dotted accent marks on
    /// the words that differ from `text_raw`, including a multi-word original
    /// and a correction in the second of two merged segments; the last line is
    /// drawn as the current line (a search hit's jump target).
    @MainActor
    static let transcripcionGlossary = SnapshotState(name: "tab-transcripcion-glossary", width: windowSize.width - MainLayout.sidebarWidth - MainLayout.listWidth, height: 360) { _ in
        func segment(_ speaker: String, _ start: Int, _ text: String, raw: String?) -> TranscriptInput.Segment {
            TranscriptInput.Segment(speaker: speaker, start_ms: start, end_ms: start + 4000, text: text, text_raw: raw)
        }
        let lines = TranscriptViewLines.build([
            segment("me", 0, "Buenos días a todos. Hoy vemos la integración con MeetingVox y el plan de pagos.",
                    raw: "Buenos días a todos. Hoy vemos la integración con miting vox y el plan de pagos."),
            segment("them", 5000, "El tablero de Grafana confirma que finanzas revisa el presupuesto.",
                    raw: "El tablero de gra fana confirma que finanzas revisa el presupuesto."),
            segment("me", 11000, "Perfecto, quedo atento.", raw: "Perfecto, quedo atento."),
            segment("me", 15000, "Entonces finanzas sube el informe a MeetingVox el viernes.",
                    raw: "Entonces finanzas sube el informe a mitin vox el viernes."),
            segment("them", 22000, "Sin glosario en esta línea.", raw: nil),
        ])
        return AnyView(TranscriptTab(state: .lines(lines), target: lines.last?.id))
    }
}
