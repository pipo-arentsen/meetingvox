import Foundation
import Testing
@testable import MeetingVox

/// Blocks a fake load until the test lets it through, so "a slow load for the
/// previous selection finishes last" is an ordering the test controls, not a
/// race it hopes for.
private actor LoadGate {
    private var open: Set<String> = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var started: [String] = []

    func pass(_ name: String) async {
        started.append(name)
        if open.contains(name) { return }
        await withCheckedContinuation { waiting[name] = $0 }
    }

    func release(_ name: String) {
        open.insert(name)
        waiting.removeValue(forKey: name)?.resume()
    }
}

@MainActor
@Suite struct SessionDetailModelTests {
    private let a = URL(fileURLWithPath: "/fake/2026.09.29-0900")
    private let b = URL(fileURLWithPath: "/fake/2026.09.29-1000")
    private let sentAt = ISO8601DateFormatter().date(from: "2026-09-24T18:00:00Z")!

    private func inputs(reason: String? = nil, summary: Bool = false) -> SessionDetailInputs {
        SessionDetailInputs(options: nil, summaryApplies: summary, minutesUnavailableReason: reason)
    }

    /// A model whose loads wait on `gate`; each result names its folder in
    /// `manualMinutes` so a test can tell whose data it holds.
    private func gated(_ gate: LoadGate) -> SessionDetailModel {
        SessionDetailModel(inputs: { inputs() }, load: { dir, _, _ in
            await gate.pass(dir.lastPathComponent)
            return SessionDetailData(dir: dir, manualMinutes: [dir.lastPathComponent])
        })
    }

    // MARK: - Loading per selection

    @Test func selectingLoadsThatSessionsData() async {
        let model = SessionDetailModel(inputs: { inputs() }, load: { dir, _, _ in
            SessionDetailData(dir: dir, manualMinutes: ["daily"])
        })
        #expect(model.data == nil)
        await model.select(a).value
        #expect(model.selected == a)
        #expect(model.data == SessionDetailData(dir: a, manualMinutes: ["daily"]))
        #expect(model.data(for: a) != nil)
        #expect(model.data(for: b) == nil, "data belongs to the selected folder only")
    }

    @Test func aSlowLoadForAnEarlierSelectionNeverOverwritesTheNewerOne() async {
        let gate = LoadGate()
        let model = gated(gate)
        let first = model.select(a)
        let second = model.select(b)
        await gate.release(b.lastPathComponent)
        await second.value
        #expect(model.data?.dir == b)

        await gate.release(a.lastPathComponent)
        await first.value
        #expect(model.selected == b)
        #expect(model.data?.dir == b, "the stale answer for A was dropped")
        #expect(model.data?.manualMinutes == [b.lastPathComponent])
    }

    @Test func aLoadFinishingInTheOtherOrderStillEndsOnTheLatestSelection() async {
        let gate = LoadGate()
        let model = gated(gate)
        let first = model.select(a)
        let second = model.select(b)
        await gate.release(a.lastPathComponent)
        await first.value
        #expect(model.data == nil, "A's answer is stale before B answers: nothing is shown for B yet")
        await gate.release(b.lastPathComponent)
        await second.value
        #expect(model.data?.dir == b)
    }

    @Test func twoLoadsOfTheSameFolderFinishingOutOfOrderKeepTheNewerRead() async {
        // A reload after a marker changed overtakes a slower earlier read of
        // the same folder: the older one must not put stale data back.
        let gate = LoadGate()
        let counter = CallCounter()
        let model = SessionDetailModel(inputs: { inputs() }, load: { dir, _, _ in
            let call = await counter.next()
            await gate.pass("call\(call)")
            return SessionDetailData(dir: dir, manualMinutes: ["call\(call)"])
        })
        let first = model.select(a)
        let second = model.reload()
        await gate.release("call2")
        await second.value
        #expect(model.data?.manualMinutes == ["call2"])

        await gate.release("call1")
        await first.value
        #expect(model.data?.manualMinutes == ["call2"], "the slower, older read of the same folder was dropped")
    }

    @Test func aSupersededLoadIsCancelled() async {
        let gate = LoadGate()
        let flags = CancelFlags()
        let counter = CallCounter()
        let model = SessionDetailModel(inputs: { inputs() }, load: { dir, _, _ in
            let call = await counter.next()
            await gate.pass("call\(call)")
            await flags.record(call, cancelled: Task.isCancelled)
            return SessionDetailData(dir: dir)
        })
        let first = model.select(a)
        let second = model.select(b)
        await gate.release("call1")
        await gate.release("call2")
        await first.value
        await second.value
        #expect(await flags.value(1) == true, "the load for the row the user left was cancelled")
        #expect(await flags.value(2) == false, "the current load was not")
    }

    @Test func clearingTheSelectionDropsAnInFlightLoad() async {
        let gate = LoadGate()
        let model = gated(gate)
        let task = model.select(a)
        model.select(nil)
        await gate.release(a.lastPathComponent)
        await task.value
        #expect(model.selected == nil)
        #expect(model.data == nil)
    }

    @Test func changingSessionClearsTheOldDataAtOnceButReloadingTheSameOneKeepsIt() async {
        let gate = LoadGate()
        let model = gated(gate)
        await gate.release(a.lastPathComponent)
        await model.select(a).value
        #expect(model.data?.dir == a)

        let reload = model.reload()
        #expect(model.data?.dir == a, "a refresh of the same session does not blank the header")
        await reload.value

        let other = model.select(b)
        #expect(model.data == nil, "another session shows nothing of A while it loads")
        await gate.release(b.lastPathComponent)
        await other.value
        #expect(model.data?.dir == b)
    }

    // MARK: - Inputs snapshot (once per reload, not per select)

    @Test func theInputsAreTakenOnceAndReusedUntilRefreshed() async {
        var reason: String? = Textos.Sesiones.sinClave
        var takes = 0
        let recorder = InputRecorder()
        let model = SessionDetailModel(inputs: { takes += 1; return inputs(reason: reason, summary: true) }, load: { dir, given, _ in
            await recorder.add(given)
            return SessionDetailData(dir: dir)
        })
        await model.select(a).value
        await model.select(b).value
        reason = nil
        await model.reload().value
        #expect(takes == 1, "selecting and reloading do not re-read config or the Keychain")
        #expect(model.inputs.minutesUnavailableReason == Textos.Sesiones.sinClave)

        model.refreshInputs()
        await model.reload().value
        #expect(takes == 2)
        #expect(model.inputs.minutesUnavailableReason == nil)
        let seen = await recorder.all
        #expect(seen.map(\.minutesUnavailableReason) == [Textos.Sesiones.sinClave, Textos.Sesiones.sinClave, Textos.Sesiones.sinClave, nil])
        #expect(seen.allSatisfy { $0.summaryApplies })
    }

    // MARK: - Memory actions with the live re-check

    private func withCommands(
        live: HindsightStatus?, now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000) }
    ) -> (SessionDetailModel, SentLog, Counter) {
        let model = SessionDetailModel(inputs: { inputs() }, load: { dir, _, _ in SessionDetailData(dir: dir) }, now: now)
        let log = SentLog()
        let reloads = Counter()
        model.commands.sendToMemory = { log.sent.append(Sent(dir: $0, action: $1, bank: $2)) }
        model.liveMemoryStatus = { _ in live }
        model.onListNeedsReload = { reloads.count += 1 }
        return (model, log, reloads)
    }

    @Test func aSendStillOfferedByTheDiskGoesThroughToTheChosenBank() async {
        let (model, log, reloads) = withCommands(live: .notSent)
        await model.select(a).value
        model.chooseMemory(.send, bank: "archivo", shownAs: .notSent, dir: a)
        #expect(log.sent == [Sent(dir: a, action: .send, bank: "archivo")])
        #expect(reloads.count == 0)
    }

    @Test func aStaleSendIsNotSentAndTheUIIsRefreshedWithAMessage() async {
        // The menu was opened, then the session became sent with the same content.
        let (model, log, reloads) = withCommands(live: .sent(sentAt, bank: "meetingvox"))
        await model.select(a).value
        model.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: a)
        #expect(log.sent.isEmpty)
        #expect(reloads.count == 1, "the list and the detail re-read the disk")
        #expect(model.notice(for: a) == Textos.Principal.memoriaCambio)
        #expect(!model.isMemoryInFlight(a), "a refused send is not in flight")
    }

    @Test func aSendIsRefusedWhenTheIntegrationWentOffAndAnOmittedSessionIsNotRevived() async {
        let (off, offLog, _) = withCommands(live: nil)
        await off.select(a).value
        off.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: a)
        #expect(offLog.sent.isEmpty)

        let (omitted, omittedLog, _) = withCommands(live: .omitted)
        await omitted.select(a).value
        omitted.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: a)
        #expect(omittedLog.sent.isEmpty)
        omitted.chooseMemory(.send, bank: nil, shownAs: .omitted, dir: a)
        #expect(omittedLog.sent == [Sent(dir: a, action: .send, bank: nil)], "the row said 'No se envía', the click lifts it")
    }

    @Test func resendAndRetryAlsoRecheck() async {
        let (model, log, reloads) = withCommands(live: .sent(sentAt, bank: nil))
        await model.select(a).value
        model.chooseMemory(.resend, bank: nil, shownAs: .sent(sentAt, bank: nil), dir: a)
        model.memoryStatusChanged()
        model.chooseMemory(.retry, bank: nil, shownAs: .error, dir: a)
        #expect(log.sent == [Sent(dir: a, action: .resend, bank: nil)])
        #expect(reloads.count == 1)
    }

    @Test func retryingTheMemoryStepGoesThroughTheSameRecheck() async {
        let (failing, failingLog, _) = withCommands(live: .error)
        await failing.select(a).value
        failing.retry(.memoria, dir: a)
        #expect(failingLog.sent == [Sent(dir: a, action: .retry, bank: nil)])

        // Sent meanwhile: a retry would resend content that is already in memory.
        let (sent, sentLog, sentReloads) = withCommands(live: .sent(sentAt, bank: nil))
        await sent.select(a).value
        sent.retry(.memoria, dir: a)
        #expect(sentLog.sent.isEmpty)
        #expect(sentReloads.count == 1)
    }

    @Test func skippingForwardsWithoutARecheck() async {
        let model = SessionDetailModel(inputs: { inputs() }, load: { dir, _, _ in SessionDetailData(dir: dir) })
        var skipped: [(URL, Bool)] = []
        model.commands.setMemorySkipped = { skipped.append(($0, $1)) }
        model.skipMemory(dir: a)
        #expect(skipped.count == 1 && skipped[0].0 == a && skipped[0].1)
    }

    // MARK: - One send at a time

    @Test func whileASendIsInFlightAnotherClickDoesNotDispatch() async {
        let (model, log, _) = withCommands(live: .notSent)
        await model.select(a).value
        model.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: a)
        #expect(model.isMemoryInFlight(a))
        model.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: a)
        model.chooseMemory(.send, bank: "archivo", shownAs: .notSent, dir: a)
        #expect(log.sent.count == 1, "no double dispatch before the status changes")
        #expect(!model.isMemoryInFlight(b), "only that session is busy")
    }

    @Test func theHindsightStatusChangeEndsTheInFlightState() async {
        let (model, log, _) = withCommands(live: .notSent)
        await model.select(a).value
        model.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: a)
        model.memoryStatusChanged()
        #expect(!model.isMemoryInFlight(a))
        model.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: a)
        #expect(log.sent.count == 2)
    }

    @Test func aStuckInFlightFlagExpires() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let (model, log, _) = withCommands(live: .notSent, now: { clock })
        await model.select(a).value
        model.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: a)
        clock = clock.addingTimeInterval(SessionDetailModel.inFlightTimeout - 1)
        #expect(model.isMemoryInFlight(a))
        clock = clock.addingTimeInterval(2)
        #expect(!model.isMemoryInFlight(a), "a send that never reported back does not block the button forever")
        model.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: a)
        #expect(log.sent.count == 2)
    }

    // MARK: - Targets come from the rendered row (no select gap)

    @Test func actionsActOnTheFolderTheyWerePassedNotOnTheSelection() async {
        let model = SessionDetailModel(inputs: { inputs() }, load: { dir, _, _ in SessionDetailData(dir: dir) })
        let log = OpenLog()
        var regenerated: [URL] = []
        var generated: [URL] = []
        var retried: [URL] = []
        var sent: [URL] = []
        model.commands.openFolder = { log.folders.append($0) }
        model.commands.openFile = { log.files.append($0) }
        model.commands.applyGlossary = { log.glossary.append($0) }
        model.commands.regenerate = { dir, _ in regenerated.append(dir) }
        model.commands.generateManual = { dir, _ in generated.append(dir) }
        model.commands.retryStage = { _, dir, _ in retried.append(dir) }
        model.commands.sendToMemory = { dir, _, _ in sent.append(dir) }
        model.liveMemoryStatus = { _ in .notSent }
        // Nothing selected yet (or another row): the load for `b` has not been asked for.
        model.select(a)

        model.perform(.openFolder, dir: b)
        model.perform(.openTranscript, dir: b)
        model.perform(.openMinutes, dir: b)
        model.perform(.applyGlossary, dir: b)
        model.perform(.openManualMinutes(id: "daily"), dir: b)
        model.regenerate(templateID: "daily", dir: b)
        model.generate(templateID: "general", dir: b)
        model.retry(.minuta, dir: b)
        model.chooseMemory(.send, bank: nil, shownAs: .notSent, dir: b)

        #expect(log.folders == [b] && log.glossary == [b] && regenerated == [b] && generated == [b] && retried == [b] && sent == [b])
        #expect(log.files == [
            b.appendingPathComponent(SessionFiles.transcriptMD), b.appendingPathComponent(SessionFiles.minutes),
            b.appendingPathComponent("minuta.daily.md"),
        ])
    }

    @Test func aFailedStepRetriesThroughItsStage() {
        let model = SessionDetailModel(inputs: { inputs() }, load: { dir, _, _ in SessionDetailData(dir: dir) })
        var retried: [Notice.Stage] = []
        model.commands.retryStage = { stage, _, _ in retried.append(stage) }
        model.retry(.transcrita, dir: a)
        model.retry(.minuta, dir: a)
        model.retry(.resumen, dir: a)
        model.retry(.grabada, dir: a)
        #expect(retried == [.transcription, .minutes, .summary])
    }

    // MARK: - A refused retry says so

    @Test func aRefusedRetryLeavesAMessageForThatSessionAndStage() {
        let model = SessionDetailModel(inputs: { inputs() }, load: { dir, _, _ in SessionDetailData(dir: dir) })
        var refuse: (@MainActor @Sendable () -> Void)?
        model.commands.retryStage = { _, _, refused in refuse = refused }
        model.retry(.resumen, dir: a)
        #expect(model.notice(for: a) == nil, "nothing to say until the stage refuses")
        refuse?()
        #expect(model.notice(for: a) == RetryRefusal.message(for: .summary))
        #expect(model.notice(for: b) == nil, "the message belongs to that session")

        model.retry(.minuta, dir: a)
        #expect(model.notice(for: a) == nil, "trying again clears the old message")
        refuse?()
        #expect(model.notice(for: a) == RetryRefusal.message(for: .minutes))
        model.dismissNotice()
        #expect(model.notice(for: a) == nil)
    }

    @Test func theMessageGoesAwayWhenAnotherSessionIsSelected() async {
        let model = SessionDetailModel(inputs: { inputs() }, load: { dir, _, _ in SessionDetailData(dir: dir) })
        var refuse: (@MainActor @Sendable () -> Void)?
        model.commands.retryStage = { _, _, refused in refuse = refused }
        await model.select(a).value
        model.retry(.transcrita, dir: a)
        refuse?()
        #expect(model.notice(for: a) != nil)
        await model.select(b).value
        await model.select(a).value
        #expect(model.notice(for: a) == nil)
    }
}

private actor InputRecorder {
    private(set) var all: [SessionDetailInputs] = []
    func add(_ inputs: SessionDetailInputs) { all.append(inputs) }
}

private actor CallCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private actor CancelFlags {
    private var flags: [Int: Bool] = [:]
    func record(_ call: Int, cancelled: Bool) { flags[call] = cancelled }
    func value(_ call: Int) -> Bool? { flags[call] }
}

private struct Sent: Equatable {
    let dir: URL
    let action: HindsightStatus.Action
    let bank: String?
}

@MainActor private final class SentLog { var sent: [Sent] = [] }
@MainActor private final class Counter { var count = 0 }
@MainActor private final class OpenLog {
    var folders: [URL] = []
    var files: [URL] = []
    var glossary: [URL] = []
}

/// What one selection reads off the main thread, over a real temp folder.
@Suite struct SessionDetailDataTests {
    private func session() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-detail-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"started": "2026-09-27T10:00:00Z", "duration_seconds": 600, "files": {"mic": "mic.caf"}}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
        try Data(#"{"engine": "fake", "model": "fake", "segments": [{"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "hola"}]}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        return dir
    }

    @Test func listsTheManualMinutesAndLeavesTheAutomaticOneOut() throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("# a".utf8).write(to: dir.appendingPathComponent("minuta.md"))
        try Data("# b".utf8).write(to: dir.appendingPathComponent("minuta.viejo.md"))
        try Data("# c".utf8).write(to: dir.appendingPathComponent("minuta.daily.md"))

        let data = SessionDetailData.load(
            dir, SessionDetailInputs(options: nil, summaryApplies: true, minutesUnavailableReason: Textos.Sesiones.sinModelo)
        )
        #expect(data.dir == dir)
        #expect(data.manualMinutes == ["daily", "viejo"])
    }

    @Test func knowsWhetherTheTranscriptMarkdownExists() throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = SessionDetailInputs.none
        #expect(SessionDetailData.load(dir, inputs).hasTranscriptMD == false)
        try Data("# t".utf8).write(to: dir.appendingPathComponent(SessionFiles.transcriptMD))
        #expect(SessionDetailData.load(dir, inputs).hasTranscriptMD == true)
    }

    @Test func readsMemoryFactsOnlyWhenTheIntegrationGaveOptions() throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let off = SessionDetailData.load(dir, SessionDetailInputs(options: nil, summaryApplies: false, minutesUnavailableReason: nil))
        #expect(off.facts == nil)
        let options = HindsightFacts.Options(ownerName: "Usuario", glossary: [], timeZone: TimeZone(identifier: "UTC")!)
        let on = SessionDetailData.load(dir, SessionDetailInputs(options: options, summaryApplies: false, minutesUnavailableReason: nil))
        #expect(on.facts?.hasTranscript == true)
        #expect(on.facts?.words == 1)
    }
}
