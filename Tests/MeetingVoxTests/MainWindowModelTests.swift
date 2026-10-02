import Foundation
import Testing
@testable import MeetingVox

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// The composition root of the main window: sidebar -> ámbito filter,
/// counts, sections, bulk classify, the live overlay and the reload on a
/// finished job. Real `MeetingsModel` over a temp root; no window.
@MainActor
@Suite final class MainWindowModelTests {
    let root: URL
    private let now = date("2026-09-27T12:00:00Z")
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-main-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try session("2026.09.27-1000", "2026-09-27T10:00:00Z", ambito: "trabajo")
        try session("2026.09.27-0900", "2026-09-27T09:00:00Z", ambito: "personal")
        try session("2026.09.26-1500", "2026-09-26T15:00:00Z", ambito: nil)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func session(_ name: String, _ started: String, ambito: String?) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ambitoField = ambito.map { #", "ambito": "\#($0)""# } ?? ""
        try Data(#"{"started": "\#(started)", "duration_seconds": 600, "files": {"mic": "mic.caf"}\#(ambitoField)}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
        try Data(#"{"engine": "fake", "model": "fake", "segments": [{"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "hola"}]}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
    }

    /// The folder URL exactly as the scan reports it (selection is keyed by
    /// it, so a hand-built URL with a trailing slash would not match).
    private func dir(_ name: String, in model: MainWindowModel) -> URL {
        model.meetings.entries.first { $0.dir.lastPathComponent == name }!.dir
    }
    private func names(_ entries: [MeetingEntry]) -> [String] { entries.map(\.dir.lastPathComponent) }

    private let manual = ManualReloadScheduler()

    private func makeModel(store: PipelineStatusStore = PipelineStatusStore()) -> MainWindowModel {
        let meetings = MeetingsModel(
            root: root, calendar: calendar, now: { [now] in now }, config: { ConfigValues(raw: [:]) }
        )
        return MainWindowModel(
            meetings: meetings, store: store, calendar: calendar, now: { [now] in now },
            reloadScheduler: manual.scheduler, library: (try? TestLibrary.make().library)!
        )
    }

    private func loaded(_ store: PipelineStatusStore = PipelineStatusStore()) async -> MainWindowModel {
        let model = makeModel(store: store)
        await model.reload().value
        return model
    }

    // MARK: - Sidebar -> ámbito filter

    @Test func selectingAnAmbitoFiltersTheListAndReunionesClearsIt() async {
        let model = await loaded()
        #expect(names(model.meetings.filtered) == ["2026.09.27-1000", "2026.09.27-0900", "2026.09.26-1500"])

        model.sidebar = .ambito(.trabajo)
        #expect(names(model.meetings.filtered) == ["2026.09.27-1000"])
        model.sidebar = .sinClasificar
        #expect(names(model.meetings.filtered) == ["2026.09.26-1500"])
        model.sidebar = .ambito(.personal)
        #expect(names(model.meetings.filtered) == ["2026.09.27-0900"])
        model.sidebar = .reuniones
        #expect(model.meetings.filtered.count == 3)
    }

    @Test func aPlaceholderEntryLeavesTheListFilterAlone() async {
        let model = await loaded()
        model.sidebar = .ambito(.trabajo)

        model.sidebar = .tareas
        #expect(model.meetings.ambitoFilter == .only(.trabajo))
        model.sidebar = .glosario
        #expect(model.meetings.ambitoFilter == .only(.trabajo))
        model.sidebar = .reuniones
        #expect(model.meetings.ambitoFilter == .all)
    }

    @Test func countsReflectEverySessionNotTheCurrentFilter() async {
        let model = await loaded()
        model.sidebar = .ambito(.trabajo)

        #expect(model.meetings.filtered.count == 1)
        #expect(model.counts.total == 3)
        #expect(model.counts.count(.only(.trabajo)) == 1)
        #expect(model.counts.count(.only(.personal)) == 1)
        #expect(model.counts.count(.unclassified) == 1)
    }

    // MARK: - List

    @Test func sectionsGroupTheShownRowsIntoHoyAndAyer() async {
        let model = await loaded()

        #expect(model.sections.map(\.title) == [Textos.Principal.hoy, Textos.Principal.ayer])
        #expect(names(model.sections[0].entries) == ["2026.09.27-1000", "2026.09.27-0900"])
        #expect(names(model.sections[1].entries) == ["2026.09.26-1500"])

        model.sidebar = .sinClasificar
        #expect(model.sections.map(\.title) == [Textos.Principal.ayer])
    }

    @Test func theFooterCountsShownOverAllSessions() async {
        let model = await loaded()
        model.sidebar = .ambito(.trabajo)
        #expect(model.footer == "1 de 3 reuniones")
    }

    @Test func theListStateIsLoadingThenRowsThenNoMatches() async {
        let model = makeModel()
        #expect(model.emptyState == .loading)

        await model.reload().value
        #expect(model.emptyState == nil)

        model.meetings.query = "nada que coincida"
        #expect(model.emptyState == .noMatches)
    }

    // MARK: - Selection

    @Test func theDetailFollowsHowManyVisibleRowsAreSelected() async {
        let model = await loaded()
        guard case .none = model.detail else { Issue.record("expected none, got \(model.detail)"); return }

        model.meetings.selection = [dir("2026.09.27-1000", in: model)]
        guard case .single(let entry) = model.detail else { Issue.record("expected single, got \(model.detail)"); return }
        #expect(entry.dir.lastPathComponent == "2026.09.27-1000")

        model.meetings.selection = [dir("2026.09.27-1000", in: model), dir("2026.09.27-0900", in: model)]
        guard case .bulk(let count) = model.detail else { Issue.record("expected bulk, got \(model.detail)"); return }
        #expect(count == 2)
        #expect(model.detail.bulkTitle == "2 seleccionadas")
    }

    @Test func aSelectedRowTheFilterHidesNeverCounts() async {
        let model = await loaded()
        model.meetings.selection = [dir("2026.09.27-1000", in: model), dir("2026.09.27-0900", in: model)]
        guard case .bulk = model.detail else { Issue.record("expected bulk, got \(model.detail)"); return }

        model.sidebar = .ambito(.trabajo) // hides the personal one
        guard case .single = model.detail else { Issue.record("expected single, got \(model.detail)"); return }
        #expect(model.bulkTargets.map(\.lastPathComponent) == ["2026.09.27-1000"])
    }

    // MARK: - Bulk classify

    @Test func classifyingTheSelectionWritesEachMetaAndUpdatesCountsWithoutARescan() async throws {
        let model = await loaded()
        model.meetings.selection = Set(model.meetings.entries.map(\.dir))
        let reloads = model.reloadCount

        model.classifySelected(as: .personal)

        for entry in model.meetings.entries {
            let meta = try JSONSerialization.jsonObject(
                with: Data(contentsOf: entry.dir.appendingPathComponent(SessionFiles.meta))
            ) as? [String: Any]
            #expect(meta?["ambito"] as? String == "personal", "\(entry.dir.lastPathComponent)")
        }
        #expect(model.counts.count(.only(.personal)) == 3)
        #expect(model.counts.count(.only(.trabajo)) == 0)
        #expect(model.reloadCount == reloads, "no rescan required")
    }

    @Test func classifyingAsNilRemovesTheAmbito() async throws {
        let model = await loaded()
        model.meetings.selection = [dir("2026.09.27-1000", in: model), dir("2026.09.27-0900", in: model)]

        model.classifySelected(as: nil)

        #expect(model.counts.count(.unclassified) == 3)
        let meta = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir("2026.09.27-1000", in: model).appendingPathComponent(SessionFiles.meta))
        ) as? [String: Any]
        #expect(meta?["ambito"] == nil)
    }

    // MARK: - Live overlay -> pill

    @Test func theRowPillFollowsTheLiveStoreAndTheRecording() async {
        let store = PipelineStatusStore()
        let model = await loaded(store)
        let entry = model.meetings.entries.first { $0.dir.lastPathComponent == "2026.09.27-1000" }!
        #expect(model.pill(for: entry) == nil)

        store.apply(.running(.minutes, folder: "2026.09.27-1000", queued: 0))
        #expect(model.pill(for: entry) == .active(.minutes))

        store.apply(.recording(dir("2026.09.27-1000", in: model), elapsed: 5))
        #expect(model.pill(for: entry) == .recording, "recording outranks everything")

        store.apply(.recording(nil, elapsed: 0))
        store.apply(.idle(.minutes))
        #expect(model.pill(for: entry) == nil)
    }

    @Test func theRecordButtonFollowsTheStore() async {
        let store = PipelineStatusStore()
        let model = await loaded(store)
        #expect(model.recordButton == .start)

        store.apply(.recording(dir("2026.09.27-1000", in: model), elapsed: 61))
        #expect(model.recordButton == .stop(elapsed: "1:01"))
    }

    // MARK: - A finished job reloads (only while the window is open, coalesced)

    @Test func aFinishedJobSchedulesOneReloadInsteadOfScanningAtOnce() async {
        let store = PipelineStatusStore()
        let model = await loaded(store)
        model.isActive = true
        let base = model.reloadCount

        store.apply(.running(.summary, folder: "2026.09.27-1000", queued: 0))
        #expect(manual.scheduledCount == 0, "starting is not finishing")
        store.apply(.idle(.summary))
        #expect(model.reloadCount == base, "the scan waits for the delay")
        #expect(manual.pending == 1)

        manual.fire()
        #expect(model.reloadCount == base + 1)
    }

    @Test func aBurstOfFinishedStagesBecomesOneScan() async {
        let store = PipelineStatusStore()
        let model = await loaded(store)
        model.isActive = true
        let base = model.reloadCount

        store.apply(.running(.minutes, folder: "A", queued: 0))
        store.apply(.running(.summary, folder: "A", queued: 0))
        store.apply(.idle(.minutes))
        store.apply(.idle(.summary))
        manual.fire()

        #expect(model.reloadCount == base + 1)
    }

    @Test func aFinishedJobWhileTheWindowIsClosedSchedulesNothing() async {
        let store = PipelineStatusStore()
        let model = await loaded(store)
        model.isActive = false
        let base = model.reloadCount

        store.apply(.running(.summary, folder: "2026.09.27-1000", queued: 0))
        store.apply(.idle(.summary))
        manual.fire()

        #expect(manual.scheduledCount == 0)
        #expect(model.reloadCount == base)
    }

    @Test func stoppingTheRecordingReloadsSoTheNewRowAppears() async {
        let store = PipelineStatusStore()
        let model = await loaded(store)
        model.isActive = true
        let base = model.reloadCount
        let recording = dir("2026.09.27-1000", in: model)

        store.apply(.recording(recording, elapsed: 0))
        for second in 1...3 { store.apply(.recording(recording, elapsed: TimeInterval(second))) }
        #expect(manual.scheduledCount == 0, "neither the start nor the tick rescans")

        store.apply(.recording(nil, elapsed: 0))
        manual.fire()
        #expect(model.reloadCount == base + 1)
    }

    @Test func stoppingTheRecordingWhileClosedDoesNotScan() async {
        let store = PipelineStatusStore()
        let model = await loaded(store)
        model.isActive = false

        store.apply(.recording(dir("2026.09.27-1000", in: model), elapsed: 0))
        store.apply(.recording(nil, elapsed: 0))

        #expect(manual.scheduledCount == 0)
    }

    @Test func scheduleReloadCoalescesAndAnImmediateReloadSupersedesIt() async {
        let model = await loaded()
        model.isActive = true
        let base = model.reloadCount

        model.scheduleReload()
        model.scheduleReload()
        model.scheduleReload()
        #expect(manual.pending == 1)

        await model.reload().value
        manual.fire()
        #expect(model.reloadCount == base + 1, "the explicit reload already covered the pending one")
    }

    @Test func closingTheWindowDropsAPendingReload() async {
        let model = await loaded()
        model.isActive = true
        let base = model.reloadCount
        model.scheduleReload()

        model.isActive = false
        manual.fire()

        #expect(model.reloadCount == base)
    }
}
