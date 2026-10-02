import Foundation
import Testing
@testable import MeetingVox

/// How the main window model turns the selected entry plus its loaded detail
/// data and the live store into the header, the stepper and the toolbar.
@MainActor
@Suite final class MainWindowDetailTests {
    let root: URL
    private let manual = ManualReloadScheduler()
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let now = ISO8601DateFormatter().date(from: "2026-09-27T12:00:00Z")!

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-main-detail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try session("2026.09.27-1000", minutes: true)
        try session("2026.09.27-0900", minutes: false)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func session(_ name: String, minutes: Bool) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"started": "2026-09-27T10:00:00Z", "duration_seconds": 600, "files": {"mic": "mic.caf", "system": "system.caf"}, "meeting_app": "teams"}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
        try Data(#"{"engine": "fake", "model": "fake", "segments": [{"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "hola"}]}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        if minutes { try Data("# Minuta".utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes)) }
    }

    private var inputTakes = 0

    private func makeModel(hindsight: Bool = true, summaryApplies: Bool = true) -> MainWindowModel {
        var raw: [String: Any] = [:]
        if hindsight { raw["hindsight"] = ["enabled": true, "bank": "meetingvox", "min_words": 0, "min_minutes": 0] }
        let config = ConfigValues(raw: raw)
        let meetings = MeetingsModel(root: root, calendar: calendar, now: { [now] in now }, config: { config })
        meetings.defaultBank = { config.hindsightBank }
        meetings.otherBanks = { ["archivo"] }
        meetings.listTemplates = { [FactoryTemplates.general, FactoryTemplates.daily] }
        let session = SessionDetailModel(
            inputs: { [self] in
                inputTakes += 1
                return SessionDetailInputs(
                    options: hindsight ? HindsightFacts.Options(config: config, timeZone: TimeZone(identifier: "UTC")!) : nil,
                    summaryApplies: summaryApplies, minutesUnavailableReason: nil
                )
            },
            load: { dir, inputs, previous in SessionDetailData.load(dir, inputs, reusing: previous) }
        )
        session.commands.sendToMemory = { _, _, _ in }
        return MainWindowModel(
            meetings: meetings, store: PipelineStatusStore(), calendar: calendar, now: { [now] in now },
            reloadScheduler: manual.scheduler, session: session, library: (try? TestLibrary.make().library)!
        )
    }

    private func entry(_ name: String, in model: MainWindowModel) -> MeetingEntry {
        model.meetings.entries.first { $0.dir.lastPathComponent == name }!
    }

    private func loaded(hindsight: Bool = true, summaryApplies: Bool = true, select name: String = "2026.09.27-1000") async -> (MainWindowModel, MeetingEntry) {
        let model = makeModel(hindsight: hindsight, summaryApplies: summaryApplies)
        await model.reload().value
        await model.meetings.factsTask?.value
        let entry = entry(name, in: model)
        await model.session.select(entry.dir).value
        return (model, entry)
    }

    @Test func headerComesFromTheEntryAndTheTemplatesTheListLoaded() async {
        let (model, entry) = await loaded()
        let header = model.header(for: entry)
        #expect(header.title == Textos.Principal.sinResumenFila)
        #expect(header.meta == "Dom 27 sep · 10:00–10:10 (10 min) · Teams")
        #expect(header.pistas == "\(Textos.Principal.pistaYo) · \(Textos.Principal.pistaOtros)")
    }

    @Test func memoryStatusReadsTheLoadedFactsAndIsNilWithTheIntegrationOff() async {
        let (on, entry) = await loaded()
        #expect(on.memoryStatus(for: entry) == .notSent)
        let (off, offEntry) = await loaded(hindsight: false)
        #expect(off.memoryStatus(for: offEntry) == nil)
    }

    @Test func stepperFollowsTheDiskThenTheLiveOverlay() async {
        let (model, entry) = await loaded(select: "2026.09.27-1000")
        #expect(model.steps(for: entry).map(\.state) == [.done, .done, .done, .pending, .pending])
        // Only "active" can come from the store; the minutes already exist, so it stays done.
        model.store.apply(.running(.minutes, folder: entry.dir.lastPathComponent, queued: 0))
        #expect(model.steps(for: entry)[2].state == .done)
        model.store.apply(.running(.summary, folder: entry.dir.lastPathComponent, queued: 0))
        #expect(model.steps(for: entry)[3].state == .active)
    }

    @Test func aFeatureThatCannotRunShowsSkippedNotPending() async {
        let (model, entry) = await loaded(summaryApplies: false)
        #expect(model.steps(for: entry)[3].state == .skipped)
    }

    @Test func aRecordingSessionShowsGrabadaAsActive() async {
        let (model, entry) = await loaded()
        model.store.apply(.recording(entry.dir, elapsed: 5))
        #expect(model.steps(for: entry)[0].state == .active)
    }

    @Test func actionsUseTheLoadedTemplatesBanksAndManualMinutes() async throws {
        let model = makeModel()
        let dir = root.appendingPathComponent("2026.09.27-1000", isDirectory: true)
        try Data("# m".utf8).write(to: dir.appendingPathComponent("minuta.daily.md"))
        await model.reload().value
        await model.meetings.factsTask?.value
        let entry = entry("2026.09.27-1000", in: model)
        await model.session.select(entry.dir).value

        let actions = model.actions(for: entry)
        #expect(actions.regenerate.regenerateWith?.choices.map(\.id) == ["general", "daily"])
        #expect(actions.memory?.banks?.map(\.bank) == [nil, "archivo"])
        #expect(actions.overflow.map(\.kind).contains(.openManualMinutes(id: "daily")))
    }

    @Test func classifyingTheOpenSessionWritesItsMetaAndPatchesTheEntry() async throws {
        let (model, entry) = await loaded()
        model.classify(entry, as: .personal)
        #expect(model.meetings.entries.first { $0.dir == entry.dir }?.ambito == .personal)
        let meta = try Data(contentsOf: entry.dir.appendingPathComponent(SessionFiles.meta))
        #expect(String(decoding: meta, as: UTF8.self).contains("personal"))
    }

    @Test func aStaleMemoryChoiceReloadsTheListAndTheDetail() async {
        let (model, entry) = await loaded()
        model.session.liveMemoryStatus = { _ in .sent(Date(), bank: "meetingvox") }
        var sent = false
        model.session.commands.sendToMemory = { _, _, _ in sent = true }
        let before = model.reloadCount
        model.session.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: entry.dir)
        #expect(!sent)
        #expect(model.reloadCount == before + 1, "the window rescans so the row says 'En memoria'")
    }

    // MARK: - Corrections

    @Test func theSummaryStepDoesNotFlickerWhileTheDetailLoads() async {
        // Reloaded, but the row's detail data has not arrived: the step already
        // knows summaries apply, so it is pending and never "skipped" first.
        let model = makeModel(summaryApplies: true)
        await model.reload().value
        let row = entry("2026.09.27-1000", in: model)
        #expect(model.session.data(for: row.dir) == nil)
        #expect(model.steps(for: row)[3].state == .pending)

        let off = makeModel(summaryApplies: false)
        await off.reload().value
        #expect(off.steps(for: entry("2026.09.27-1000", in: off))[3].state == .skipped)
    }

    @Test func configAndKeyAreReadOncePerReloadNotPerSelection() async {
        let model = makeModel()
        await model.reload().value
        let afterFirstReload = inputTakes
        await model.session.select(entry("2026.09.27-1000", in: model).dir).value
        await model.session.select(entry("2026.09.27-0900", in: model).dir).value
        await model.session.select(entry("2026.09.27-1000", in: model).dir).value
        #expect(inputTakes == afterFirstReload, "three selections read nothing new")
        await model.reload().value
        #expect(inputTakes == afterFirstReload + 1)
    }

    @Test func aManualMinutaWrittenByAJobShowsUpInTheOverflowWhenTheStageEnds() async throws {
        let (model, entry) = await loaded()
        model.isActive = true
        #expect(!model.actions(for: entry).overflow.contains { $0.kind == .openManualMinutes(id: "daily") })

        // "Generar minuta con…" wrote a file; the coordinator's status leaves the folder.
        try Data("# m".utf8).write(to: entry.dir.appendingPathComponent("minuta.daily.md"))
        model.store.apply(.running(.minutes, folder: entry.dir.lastPathComponent, queued: 0))
        model.store.apply(.idle(.minutes))
        manual.fire()
        await model.session.loadTask?.value

        #expect(model.actions(for: entry).overflow.contains { $0.kind == .openManualMinutes(id: "daily") })
    }

    @Test func openingTheTranscriptNeedsTheMarkdownFileOnceTheDetailKnowsIt() async {
        let model = makeModel()
        await model.reload().value
        let row = entry("2026.09.27-1000", in: model)
        let before = model.actions(for: row).overflow.first { $0.kind == .openTranscript }
        #expect(before?.isEnabled == true, "until it loads, the transcript marker stands in")
        await model.session.select(row.dir).value
        let after = model.actions(for: row).overflow.first { $0.kind == .openTranscript }
        #expect(after?.isEnabled == false, "the fixture has transcript.json but no transcript.md")
        #expect(model.actions(for: row).overflow.first { $0.kind == .openMinutes }?.isEnabled == true)
    }

    @Test func aSendInFlightDisablesTheButtonUntilTheHindsightStatusChanges() async {
        let (model, entry) = await loaded()
        model.session.liveMemoryStatus = { _ in .notSent }
        #expect(model.actions(for: entry).memory?.isEnabled == true)
        model.session.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: entry.dir)
        #expect(model.actions(for: entry).memory?.isEnabled == false)
        #expect(model.actions(for: entry).memory?.quickSend == nil)
        model.hindsightStatusChanged()
        #expect(model.actions(for: entry).memory?.isEnabled == true)
    }

    @Test func hindsightStatusChangedAlsoSchedulesOneReload() async {
        let (model, _) = await loaded()
        let before = manual.scheduledCount
        model.hindsightStatusChanged()
        #expect(manual.scheduledCount == before + 1)
    }

    @Test func aSendableSessionOffersTheStepperQuickSendToTheDefaultBank() async {
        let (model, entry) = await loaded()
        #expect(model.actions(for: entry).memory?.quickSend == DetailActions.QuickSend(action: .send, bank: nil))
    }
}
