import Foundation
import Testing
@testable import MeetingVox

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// "Abrir" / "Ver reunión" / "Última" on the main window: select that session
/// alone, clear whatever would hide it, optionally land on a tab; a folder
/// that does not exist only brings the window up.
@MainActor
@Suite final class MainWindowFocusTests {
    let root: URL
    private let now = date("2026-09-27T12:00:00Z")
    private let manual = ManualReloadScheduler()
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-main-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try session("2026.09.27-1000", "2026-09-27T10:00:00Z", ambito: "trabajo")
        try session("2026.09.27-0900", "2026-09-27T09:00:00Z", ambito: "personal")
        try session("2026.06.01-1500", "2026-06-01T15:00:00Z", ambito: nil)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func session(_ name: String, _ started: String, ambito: String?) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ambitoField = ambito.map { #", "ambito": "\#($0)""# } ?? ""
        try Data(#"{"started": "\#(started)", "duration_seconds": 600, "files": {"mic": "mic.caf"}\#(ambitoField)}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
    }

    private func loaded() async -> MainWindowModel {
        let meetings = MeetingsModel(
            root: root, calendar: calendar, now: { [now] in now }, config: { ConfigValues(raw: [:]) }
        )
        let model = MainWindowModel(
            meetings: meetings, store: PipelineStatusStore(), calendar: calendar, now: { [now] in now },
            reloadScheduler: manual.scheduler, library: (try? TestLibrary.make().library)!
        )
        await model.reload().value
        return model
    }

    private func dir(_ name: String, in model: MainWindowModel) -> URL {
        model.meetings.entries.first { $0.dir.lastPathComponent == name }!.dir
    }

    @Test func focusSelectsTheSessionAloneAndClearsWhatHidesIt() async {
        let model = await loaded()
        let target = dir("2026.09.27-0900", in: model)
        model.meetings.query = "nada que coincida"
        model.meetings.selectedClient = "Otro"
        model.sidebar = .ambito(.trabajo)
        model.meetings.selection = [dir("2026.09.27-1000", in: model), target]

        model.focus(on: target)

        #expect(model.meetings.selection == [target], "the multi-selection is gone")
        #expect(model.meetings.query.isEmpty)
        #expect(model.meetings.selectedClient == nil)
        #expect(model.sidebar == .reuniones)
        #expect(model.meetings.ambitoFilter == .all)
        guard case .single(let shown) = model.detail else {
            Issue.record("expected a single-session detail")
            return
        }
        #expect(shown.dir == target)
    }

    @Test func focusLeavesTheTareasPageSoTheListIsShownAgain() async {
        let model = await loaded()
        model.sidebar = .tareas
        model.focus(on: dir("2026.09.27-1000", in: model))
        #expect(model.sidebar == .reuniones)
    }

    @Test func focusReachesASessionOlderThanTheLoadedWindow() async {
        let model = await loaded()
        let old = dir("2026.06.01-1500", in: model)
        #expect(!model.meetings.filtered.contains { $0.dir == old })

        model.focus(on: old)

        #expect(model.meetings.filtered.contains { $0.dir == old })
        #expect(model.meetings.selection == [old])
    }

    @Test func focusLandsOnTheRequestedTabAndKeepsTheCurrentOneWithoutARequest() async {
        let model = await loaded()
        let target = dir("2026.09.27-1000", in: model)
        model.tab = .transcripcion

        model.focus(on: target)
        #expect(model.tab == .transcripcion)

        model.focus(on: target, tab: .minuta)
        #expect(model.tab == .minuta)
    }

    @Test func aFolderThatDoesNotExistChangesNothing() async {
        let model = await loaded()
        let keep = dir("2026.09.27-1000", in: model)
        model.meetings.selection = [keep]
        model.meetings.query = "hola"
        model.sidebar = .ambito(.trabajo)
        model.tab = .transcripcion

        model.focus(on: root.appendingPathComponent("2026.01.01-0000", isDirectory: true), tab: .minuta)

        #expect(model.meetings.selection == [keep])
        #expect(model.meetings.query == "hola")
        #expect(model.sidebar == .ambito(.trabajo))
        #expect(model.tab == .transcripcion)
    }

    @Test func aSessionRecordedSinceTheLastScanIsSelectedOnceTheNextScanFindsIt() async throws {
        let model = await loaded()
        try session("2026.09.27-1100", "2026-09-27T11:00:00Z", ambito: nil)
        let fresh = root.appendingPathComponent("2026.09.27-1100", isDirectory: true)

        model.focus(on: fresh)
        await model.reload().value

        #expect(model.meetings.selection.map(\.lastPathComponent) == ["2026.09.27-1100"])
    }

    @Test func theTabStartsOnResumen() async {
        let model = await loaded()
        #expect(model.tab == .resumen)
    }
}
