import Foundation
import Testing
@testable import MeetingVox

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

@MainActor
@Suite final class MeetingsModelTests {
    let root: URL
    private let now = date("2026-09-27T12:00:00Z")
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-meetings-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try session("2026.09.20-1000", "2026-09-20T10:00:00Z")
        try session("2026.08.15-1000", "2026-08-15T10:00:00Z")
        try session("2026.06.01-1000", "2026-06-01T10:00:00Z", title: "Presupuesto Proveedor", client: "Proveedor")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func session(_ name: String, _ started: String, title: String? = nil, client: String? = nil) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"started": "\#(started)", "duration_seconds": 600, "files": {"mic": "mic.caf"}}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
        try Data(#"{"engine": "fake", "model": "fake", "segments": [{"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "hola"}]}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        if let title {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(MeetingSummary(
                title: title, summary: "Resumen.", client: client, topics: [], participants: [],
                source: .transcript, model: "m/x", generatedAt: date(started)
            )).write(to: dir.appendingPathComponent(SessionFiles.summaryJSON))
        }
    }

    private func makeModel(hindsight: Bool = true) -> MeetingsModel {
        MeetingsModel(
            root: root, calendar: calendar, now: { [now] in now },
            config: { ConfigValues(raw: ["hindsight": ["enabled": hindsight, "bank": "meetingvox"]]) }
        )
    }

    private func names(_ entries: [MeetingEntry]) -> [String] { entries.map(\.dir.lastPathComponent) }
    private func factNames(_ model: MeetingsModel) -> Set<String> { Set(model.facts.keys.map(\.lastPathComponent)) }

    @Test func opensOnTheLast30DaysWithFactsOnlyForThem() async {
        let model = makeModel()
        await model.reload().value
        #expect(names(model.filtered) == ["2026.09.20-1000"])
        #expect(factNames(model) == ["2026.09.20-1000"])
        #expect(model.footer == Textos.Indice.contador(1, 3))
        #expect(model.canLoadOlder)
        // One word, below the default 150-word threshold.
        #expect(model.hindsightStatus(for: model.filtered[0]) == .short)
        #expect(model.hindsightStatus(for: model.entries.first { $0.dir.lastPathComponent == "2026.08.15-1000" }!) == nil)
    }

    @Test func loadOlderAddsACalendarMonthUntilNothingIsOlder() async {
        let model = makeModel()
        await model.reload().value

        model.loadOlder()
        await model.factsTask?.value
        #expect(names(model.filtered) == ["2026.09.20-1000", "2026.08.15-1000"])
        #expect(factNames(model) == ["2026.09.20-1000", "2026.08.15-1000"])
        #expect(model.canLoadOlder)

        model.loadOlder()
        model.loadOlder()
        await model.factsTask?.value
        #expect(model.filtered.count == 3)
        #expect(!model.canLoadOlder)
    }

    @Test func searchCoversEverySessionAndReadsFactsOnlyForResults() async {
        let model = makeModel()
        await model.reload().value

        model.query = "proveedor"
        await model.factsTask?.value
        #expect(names(model.filtered) == ["2026.06.01-1000"])
        #expect(factNames(model) == ["2026.09.20-1000", "2026.06.01-1000"])
        #expect(!model.canLoadOlder)
        #expect(model.footer == Textos.Indice.contador(1, 3))

        model.query = ""
        model.selectedClient = "Proveedor"
        await model.factsTask?.value
        #expect(names(model.filtered) == ["2026.06.01-1000"])
    }

    @Test func resetWindowGoesBackTo30Days() async {
        let model = makeModel()
        await model.reload().value
        model.loadOlder()
        await model.factsTask?.value
        model.resetWindow()
        #expect(names(model.filtered) == ["2026.09.20-1000"])
    }

    // MARK: - focus(on:) ("Ver reunión" on a notice)

    private func dir(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    private func selectedNames(_ model: MeetingsModel) -> [String] { model.selection.map(\.lastPathComponent).sorted() }

    @Test func focusSelectsTheSessionAndAsksTheListToScrollToIt() async {
        let model = makeModel()
        await model.reload().value

        model.focus(on: dir("2026.09.20-1000"))

        #expect(selectedNames(model) == ["2026.09.20-1000"])
        #expect(model.scrollTarget?.lastPathComponent == "2026.09.20-1000")
    }

    @Test func focusClearsEveryFilterThatCouldHideTheSession() async {
        let model = makeModel()
        await model.reload().value
        model.query = "proveedor"
        model.selectedClient = "Proveedor"
        model.range = .last7Days
        model.ambitoFilter = .only(.personal)
        model.typeFilter = .noMinutes
        #expect(model.filtered.isEmpty)

        model.focus(on: dir("2026.09.20-1000"))

        #expect(model.query.isEmpty)
        #expect(model.selectedClient == nil)
        #expect(model.range == .any)
        #expect(model.ambitoFilter == .all)
        #expect(model.typeFilter == nil)
        #expect(names(model.filtered) == ["2026.09.20-1000"])
    }

    @Test func focusLoadsOlderMonthsUntilTheSessionIsShown() async {
        let model = makeModel()
        await model.reload().value
        #expect(names(model.filtered) == ["2026.09.20-1000"])

        model.focus(on: dir("2026.06.01-1000"))

        #expect(names(model.filtered).contains("2026.06.01-1000"))
        #expect(model.extraMonths >= 3)
        #expect(selectedNames(model) == ["2026.06.01-1000"])
        #expect(model.scrollTarget?.lastPathComponent == "2026.06.01-1000")
        await model.factsTask?.value
        #expect(factNames(model).contains("2026.06.01-1000"))
    }

    @Test func focusBeforeTheFirstLoadWaitsForTheScan() async {
        let model = makeModel()

        model.focus(on: dir("2026.08.15-1000"))
        #expect(model.scrollTarget == nil)

        await model.reload().value

        #expect(selectedNames(model) == ["2026.08.15-1000"])
        #expect(model.scrollTarget?.lastPathComponent == "2026.08.15-1000")
        #expect(names(model.filtered).contains("2026.08.15-1000"))
    }

    @Test func focusOnASessionThatIsNotOnDiskDoesNothingAndDoesNotLinger() async {
        let model = makeModel()
        await model.reload().value

        model.focus(on: dir("2026.01.01-0000"))
        #expect(model.scrollTarget == nil)
        #expect(model.selection.isEmpty)

        // A later reload must not resurrect the stale request.
        await model.reload().value
        #expect(model.scrollTarget == nil)
        #expect(model.selection.isEmpty)
    }

    @Test func focusOnASessionRecordedSinceTheLastScanWaitsForTheNextOne() async throws {
        let model = makeModel()
        await model.reload().value
        try session("2026.09.26-0900", "2026-09-26T09:00:00Z")

        model.focus(on: dir("2026.09.26-0900"))
        #expect(model.scrollTarget == nil)

        await model.reload().value
        #expect(selectedNames(model) == ["2026.09.26-0900"])
        #expect(model.scrollTarget?.lastPathComponent == "2026.09.26-0900")
    }

    @Test func focusReplacesAnEarlierSelection() async {
        let model = makeModel()
        await model.reload().value
        model.selection = [dir("2026.09.20-1000"), dir("2026.08.15-1000")]

        model.focus(on: dir("2026.08.15-1000"))

        #expect(selectedNames(model) == ["2026.08.15-1000"])
    }

    @Test func theScrollTargetIsConsumedOnce() async {
        let model = makeModel()
        await model.reload().value
        model.focus(on: dir("2026.09.20-1000"))

        model.consumeScrollTarget()

        #expect(model.scrollTarget == nil)
        #expect(selectedNames(model) == ["2026.09.20-1000"])
    }

    @Test func noFactsWhileTheIntegrationIsOff() async {
        let model = makeModel(hindsight: false)
        await model.reload().value
        #expect(model.facts.isEmpty)
        #expect(model.hindsightStatus(for: model.filtered[0]) == nil)
    }

    /// `hindsightStatus(for:)` must
    /// reuse the snapshot taken by `reload()` instead of re-parsing
    /// config.json for every row.
    @Test func hindsightStatusReusesTheReloadSnapshotInsteadOfReparsingConfigPerRow() async {
        var configReads = 0
        let model = MeetingsModel(
            root: root, calendar: calendar, now: { [now] in now },
            config: {
                configReads += 1
                return ConfigValues(raw: ["hindsight": ["enabled": true, "bank": "meetingvox"]])
            }
        )
        await model.reload().value
        let readsAfterReload = configReads
        #expect(readsAfterReload > 0)

        for entry in model.entries {
            _ = model.hindsightStatus(for: entry)
            _ = model.hindsightStatus(for: entry)
        }
        #expect(configReads == readsAfterReload, "rows must reuse the snapshot, not call config() again")
    }

    /// Same finding: `otherBanksSnapshot` is read once per `reload()`, not
    /// once per row.
    @Test func otherBanksSnapshotIsCachedPerReload() async {
        var calls = 0
        let model = makeModel()
        model.otherBanks = { calls += 1; return ["archivo"] }
        await model.reload().value
        #expect(calls == 1)

        _ = model.otherBanksSnapshot
        _ = model.otherBanksSnapshot
        #expect(calls == 1)
        #expect(model.otherBanksSnapshot == ["archivo"])
    }

    /// Same reasoning for the default bank: read once per `reload()`, not
    /// once per row.
    @Test func defaultBankSnapshotIsCachedPerReload() async {
        var calls = 0
        let model = makeModel()
        model.defaultBank = { calls += 1; return "meetingvox" }
        await model.reload().value
        #expect(calls == 1)

        _ = model.defaultBankSnapshot
        _ = model.defaultBankSnapshot
        #expect(calls == 1)
        #expect(model.defaultBankSnapshot == "meetingvox")
    }

    /// A session with an optional ámbito and a `minuta.md` whose provenance
    /// header names `headerTemplate`.
    @discardableResult
    private func classifiedSession(
        _ name: String, _ started: String, ambito: String? = nil, headerTemplate: String? = nil
    ) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta: [String: Any] = ["started": started, "duration_seconds": 600]
        if let ambito { meta["ambito"] = ambito }
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent(SessionFiles.meta))
        if let headerTemplate {
            let header = MinutesCoordinator.provenance(
                model: "m/x", templateID: headerTemplate, generatedAt: date(started), chunked: false
            )
            try Data((header + "\n\n# Minuta\n").utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes))
        }
        return dir
    }

    @Test func ambitoAndTypeFiltersSearchEverySessionAndCombine() async throws {
        try classifiedSession("2026.06.02-1000", "2026-06-02T10:00:00Z", ambito: "personal", headerTemplate: "familiar")
        let model = makeModel()
        model.listTemplates = { [FactoryTemplates.general, FactoryTemplates.familiar] }
        await model.reload().value
        #expect(names(model.filtered) == ["2026.09.20-1000"])

        model.ambitoFilter = .only(.personal)
        await model.factsTask?.value
        #expect(names(model.filtered) == ["2026.06.02-1000"])
        #expect(!model.canLoadOlder)
        #expect(factNames(model).contains("2026.06.02-1000"))

        model.ambitoFilter = .unclassified
        #expect(names(model.filtered) == ["2026.09.20-1000", "2026.08.15-1000", "2026.06.01-1000"])

        model.ambitoFilter = .all
        model.typeFilter = .template("familiar")
        #expect(names(model.filtered) == ["2026.06.02-1000"])
        #expect(model.types == [.template("familiar"), .noMinutes])
        #expect(model.types[0].label(templates: model.templates) == "Reunión familiar")

        model.query = "proveedor"
        #expect(model.filtered.isEmpty)
        model.query = ""
        model.typeFilter = .noMinutes
        model.selectedClient = "Proveedor"
        #expect(names(model.filtered) == ["2026.06.01-1000"])
    }

    /// Review Focus 4.
    @Test func aTypeFilterThatNoLongerExistsResetsOnReload() async throws {
        let dir = try classifiedSession("2026.09.21-1000", "2026-09-21T10:00:00Z", headerTemplate: "familiar")
        let model = makeModel()
        await model.reload().value
        model.typeFilter = .template("familiar")
        #expect(names(model.filtered) == ["2026.09.21-1000"])

        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.minutes))
        await model.reload().value

        #expect(model.typeFilter == nil)
        #expect(names(model.filtered) == ["2026.09.21-1000", "2026.09.20-1000"])
    }

    private func meta(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent(SessionFiles.meta))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func classifyWritesEachVisibleSelectedSessionAndPatchesRows() async throws {
        let model = makeModel()
        await model.reload().value
        model.loadOlder()
        model.loadOlder()
        model.loadOlder()
        await model.factsTask?.value
        model.selection = Set(model.filtered.map(\.dir))
        #expect(model.selectedVisible.count == 3)

        model.classify(model.selectedVisible, as: .trabajo)

        for name in ["2026.09.20-1000", "2026.08.15-1000", "2026.06.01-1000"] {
            #expect(try meta(name)["ambito"] as? String == "trabajo")
            #expect(try meta(name)["duration_seconds"] as? Int == 600)
        }
        #expect(model.entries.allSatisfy { $0.ambito == .trabajo })

        model.classify(model.selectedVisible, as: nil)

        #expect(try meta("2026.09.20-1000")["ambito"] == nil)
        #expect(model.entries.allSatisfy { $0.ambito == nil })
    }

    // MARK: - Telling the other window

    private func makeModel(notifications: NotificationCenter) -> MeetingsModel {
        MeetingsModel(
            root: root, calendar: calendar, now: { [now] in now },
            config: { ConfigValues(raw: [:]) }, notifications: notifications
        )
    }

    private func observe(_ spy: SpyNotificationCenter) -> PostLog {
        let log = PostLog()
        _ = spy.addObserver(forName: .meetingVoxMeetingIndexDidChange, object: nil, queue: nil) { note in
            log.record(note.object as AnyObject?)
        }
        return log
    }

    private final class PostLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _senders: [AnyObject?] = []
        var senders: [AnyObject?] { lock.withLock { _senders } }
        func record(_ sender: AnyObject?) { lock.withLock { _senders.append(sender) } }
    }

    @Test func aBulkClassifyAnnouncesOneIndexChangeSoTheOtherWindowReloads() async throws {
        let spy = SpyNotificationCenter()
        let log = observe(spy)
        let model = makeModel(notifications: spy)
        await model.reload().value
        model.loadOlder()
        model.loadOlder()
        model.loadOlder()
        await model.factsTask?.value
        model.selection = Set(model.filtered.map(\.dir))

        model.classify(model.selectedVisible, as: .personal)

        #expect(log.senders.count == 1, "one post for the whole batch")
        #expect(log.senders.first.flatMap { $0 } === model, "the sender is the model, so its own window can skip it")
    }

    @Test func nothingChangedMeansNothingAnnounced() async throws {
        let spy = SpyNotificationCenter()
        let log = observe(spy)
        let model = makeModel(notifications: spy)
        await model.reload().value

        model.classify([], as: .trabajo)
        model.classify([root.appendingPathComponent("no-such-session")], as: .trabajo)

        #expect(log.senders.isEmpty)
    }

    @Test func aBatchWithOneFailureStillAnnouncesTheWritesThatHappened() async throws {
        let spy = SpyNotificationCenter()
        let log = observe(spy)
        let model = makeModel(notifications: spy)
        await model.reload().value
        let real = try #require(model.entries.first).dir

        model.classify([root.appendingPathComponent("no-such-session"), real], as: .trabajo)

        #expect(log.senders.count == 1)
        #expect(try meta(real.lastPathComponent)["ambito"] as? String == "trabajo")
    }

    /// Review Focus 3.
    @Test func classifyOnlyTouchesSelectedRowsTheListShows() async throws {
        let model = makeModel()
        await model.reload().value
        model.selection = Set(model.entries.map(\.dir))

        #expect(names(model.filtered) == ["2026.09.20-1000"])
        #expect(model.selectedVisible.map(\.lastPathComponent) == ["2026.09.20-1000"])

        model.classify(model.selectedVisible, as: .personal)

        #expect(try meta("2026.09.20-1000")["ambito"] as? String == "personal")
        #expect(try meta("2026.06.01-1000")["ambito"] == nil)
        #expect(try meta("2026.08.15-1000")["ambito"] == nil)
    }

    /// Review Focus 2.
    @Test func aSessionWhoseMetaCannotBeUpdatedIsLeftAloneAndTheRestStillChange() async throws {
        let bad = root.appendingPathComponent("2026.09.19-1000", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        let corrupt = Data("{\"started\": ".utf8)
        try corrupt.write(to: bad.appendingPathComponent(SessionFiles.meta))
        let model = makeModel()
        await model.reload().value
        let targets = model.filtered.map(\.dir)
        #expect(targets.map(\.lastPathComponent) == ["2026.09.20-1000", "2026.09.19-1000"])

        model.classify(targets, as: .profesional)

        #expect(try Data(contentsOf: bad.appendingPathComponent(SessionFiles.meta)) == corrupt)
        #expect(model.entries.first { $0.dir.lastPathComponent == "2026.09.19-1000" }?.ambito == nil)
        #expect(try meta("2026.09.20-1000")["ambito"] as? String == "profesional")
        #expect(model.entries.first { $0.dir.lastPathComponent == "2026.09.20-1000" }?.ambito == .profesional)
    }
}

// MARK: - hasLoaded (the main window's empty-root state)

@MainActor
@Suite final class MeetingsModelLoadedFlagTests {
    private func makeRoot(sessions: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-meetings-loaded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for n in 0..<sessions {
            let dir = root.appendingPathComponent("2026.09.2\(n)-1000", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"started": "2026-09-2\#(n)T10:00:00Z", "files": {"mic": "mic.caf"}}"#.utf8)
                .write(to: dir.appendingPathComponent(SessionFiles.meta))
        }
        return root
    }

    @Test func hasLoadedFlipsOnlyAfterTheFirstScanPublishes() async throws {
        let root = try makeRoot(sessions: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MeetingsModel(root: root, config: { ConfigValues(raw: [:]) })
        #expect(!model.hasLoaded)

        let scan = model.reload()
        #expect(!model.hasLoaded, "the scan is still running")
        await scan.value
        #expect(model.hasLoaded)
        #expect(model.entries.count == 1)

        await model.reload().value
        #expect(model.hasLoaded, "a later rescan does not un-load the list")
    }

    @Test func anEmptyRootStillCountsAsLoaded() async throws {
        let root = try makeRoot(sessions: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MeetingsModel(root: root, config: { ConfigValues(raw: [:]) })

        await model.reload().value

        #expect(model.hasLoaded)
        #expect(model.entries.isEmpty)
    }
}
