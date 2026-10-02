import Foundation
import Testing
@testable import MeetingVox

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// "Mover a la papelera…" through the window model: the confirmation state,
/// the effects it runs and what it cleans up. Temp root and a fake trasher —
/// never the real Trash, never a Hindsight server.
@MainActor
@Suite final class MainWindowTrashTests {
    let root: URL
    let fakeTrash: URL
    private let now = date("2026-09-27T12:00:00Z")
    private let manual = ManualReloadScheduler()
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-trash-model-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Recordings", isDirectory: true)
        fakeTrash = base.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        try session("2026.09.27-1000", "2026-09-27T10:00:00Z")
        try session("2026.09.27-0900", "2026-09-27T09:00:00Z")
        try session("2026.09.26-1500", "2026-09-26T15:00:00Z")
    }

    deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    private func session(_ name: String, _ started: String) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"started": "\#(started)", "duration_seconds": 600, "files": {"mic": "mic.caf"}}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.meta))
        try Data(#"{"engine": "fake", "model": "fake", "segments": [{"speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "hola"}]}"#.utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON))
    }

    private func markSent(_ name: String) throws {
        try HindsightFacts.writeJSON(
            HindsightSentRecord(documentID: "mv-\(name)", contentHash: "h", operationID: "op", sentAt: now, bank: "meetingvox"),
            root.appendingPathComponent(name), SessionFiles.hindsightSent
        )
    }

    private final class Spy: @unchecked Sendable {
        var memory: [String] = []
        var trashed: [String] = []
        var reindexed = 0
        var memoryAnswer: HindsightCoordinator.DeleteResult = .deleted
    }

    private func loaded(
        store: PipelineStatusStore = PipelineStatusStore(), memoryOn: Bool = true, spy: Spy
    ) async -> MainWindowModel {
        let meetings = MeetingsModel(
            root: root, calendar: calendar, now: { [now] in now }, config: { ConfigValues(raw: [:]) }
        )
        let session = SessionDetailModel(inputs: {
            SessionDetailInputs(
                options: memoryOn ? HindsightFacts.Options(ownerName: "Usuario", glossary: [], timeZone: .gmt) : nil,
                summaryApplies: false, minutesUnavailableReason: nil
            )
        })
        session.commands.reindex = { spy.reindexed += 1 }
        let fakeTrash = self.fakeTrash
        let model = MainWindowModel(
            meetings: meetings, store: store, calendar: calendar, now: { [now] in now },
            reloadScheduler: manual.scheduler, session: session, library: (try? TestLibrary.make().library)!
        )
        model.trashEffects = MainWindowModel.TrashEffects(
            deleteFromMemory: { dir in
                spy.memory.append(dir.lastPathComponent)
                return spy.memoryAnswer
            },
            trash: { dir in
                spy.trashed.append(dir.lastPathComponent)
                try FileManager.default.moveItem(at: dir, to: fakeTrash.appendingPathComponent(dir.lastPathComponent))
            }
        )
        session.refreshInputs()
        await model.reload().value
        return model
    }

    private func dir(_ name: String, _ model: MainWindowModel) -> URL {
        model.meetings.entries.first { $0.dir.lastPathComponent == name }!.dir
    }

    @Test func requestingBuildsAPlanAndCancelClearsIt() async {
        let spy = Spy()
        let model = await loaded(spy: spy)
        await model.requestTrash([dir("2026.09.27-1000", model)]).value
        #expect(model.trashRequest?.plan.trashable.count == 1)
        model.cancelTrash()
        #expect(model.trashRequest == nil)
        #expect(spy.trashed.isEmpty)
    }

    @Test func confirmingMovesTheFoldersAndCleansUp() async throws {
        let spy = Spy()
        let model = await loaded(spy: spy)
        let a = dir("2026.09.27-1000", model), b = dir("2026.09.27-0900", model)
        model.meetings.selection = [a, b]
        await model.requestTrash(model.bulkTargets).value

        await model.confirmTrash(deleteFromMemory: false).value
        await model.reload().value

        #expect(Set(spy.trashed) == ["2026.09.27-1000", "2026.09.27-0900"])
        #expect(model.trashRequest == nil)
        #expect(model.meetings.selection.isEmpty)
        #expect(model.meetings.entries.map(\.dir.lastPathComponent) == ["2026.09.26-1500"])
        #expect(spy.reindexed == 1)
        #expect(model.trashProblem == nil)
        #expect(!FileManager.default.fileExists(atPath: a.path))
    }

    @Test func memoryIsNotTouchedUnlessAskedAndOffered() async throws {
        let spy = Spy()
        try markSent("2026.09.27-1000")
        let model = await loaded(spy: spy)
        await model.requestTrash([dir("2026.09.27-1000", model)]).value
        #expect(model.trashRequest?.plan.offersMemoryDelete == true)

        await model.confirmTrash(deleteFromMemory: false).value
        #expect(spy.memory.isEmpty)
        #expect(spy.trashed == ["2026.09.27-1000"])
    }

    @Test func askingForMemoryDeleteDeletesThenTrashes() async throws {
        let spy = Spy()
        try markSent("2026.09.27-1000")
        let model = await loaded(spy: spy)
        await model.requestTrash([dir("2026.09.27-1000", model), dir("2026.09.26-1500", model)]).value

        await model.confirmTrash(deleteFromMemory: true).value

        #expect(spy.memory.contains("2026.09.27-1000"))
        #expect(Set(spy.trashed) == ["2026.09.27-1000", "2026.09.26-1500"])
    }

    @Test func aMemoryFailureKeepsTheSessionAndSaysSo() async throws {
        let spy = Spy()
        spy.memoryAnswer = .failed("unauthorized (HTTP 401)")
        try markSent("2026.09.27-1000")
        let model = await loaded(spy: spy)
        let a = dir("2026.09.27-1000", model)
        await model.requestTrash([a]).value

        await model.confirmTrash(deleteFromMemory: true).value

        #expect(spy.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(model.trashProblem == Textos.Papelera.memoriaFallo)
        model.dismissTrashProblem()
        #expect(model.trashProblem == nil)
    }

    @Test func theMemoryOptionIsIgnoredWhenTheIntegrationIsOff() async throws {
        let spy = Spy()
        try markSent("2026.09.27-1000")
        let model = await loaded(memoryOn: false, spy: spy)
        await model.requestTrash([dir("2026.09.27-1000", model)]).value
        #expect(model.trashRequest?.plan.offersMemoryDelete == false)

        await model.confirmTrash(deleteFromMemory: true).value
        #expect(spy.memory.isEmpty)
        #expect(spy.trashed == ["2026.09.27-1000"])
    }

    @Test func theRecordingFolderAndBusySessionsAreSkipped() async throws {
        let spy = Spy()
        let store = PipelineStatusStore()
        let model = await loaded(store: store, spy: spy)
        let recording = dir("2026.09.27-1000", model), busy = dir("2026.09.27-0900", model)
        store.apply(.recording(recording, elapsed: 1))
        store.apply(.running(.summary, folder: busy.lastPathComponent, queued: 0))

        await model.requestTrash([recording, busy, dir("2026.09.26-1500", model)]).value
        #expect(model.trashRequest?.plan.blocked.count == 2)
        await model.confirmTrash(deleteFromMemory: false).value

        #expect(spy.trashed == ["2026.09.26-1500"])
        #expect(FileManager.default.fileExists(atPath: recording.path))
        #expect(FileManager.default.fileExists(atPath: busy.path))
    }

    @Test func aTrashFailureIsReported() async throws {
        let spy = Spy()
        let model = await loaded(spy: spy)
        model.trashEffects.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
        await model.requestTrash([dir("2026.09.27-1000", model)]).value

        await model.confirmTrash(deleteFromMemory: false).value

        #expect(model.trashProblem == Textos.Papelera.noSePudoMover)
    }

    @Test func theDefaultEffectsNeverTouchTheRealTrash() async {
        let spy = Spy()
        let model = await loaded(spy: spy)
        let defaults = MainWindowModel.TrashEffects()
        #expect((try? defaults.trash(dir("2026.09.27-1000", model))) == nil)
    }

    @Test func theDetailMenuAsksForTheSheetOnItsOwnRow() async {
        let model = await loaded(spy: Spy())
        let a = dir("2026.09.27-1000", model)
        model.session.perform(.moveToTrash, dir: a)
        await model.trashPlanning?.value
        #expect(model.trashRequest?.plan.trashable == [a])
    }

    @Test func nothingToDoLeavesNoSheet() async {
        let model = await loaded(spy: Spy())
        await model.requestTrash([]).value
        #expect(model.trashRequest == nil)
    }

    /// A transcription that failed for good leaves meta.json and nothing else.
    private func failedTranscription(_ name: String) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionFiles.transcriptJSON))
    }

    @Test func aFailedTranscriptionCanBeTrashed() async throws {
        try failedTranscription("2026.09.27-1000")
        let model = await loaded(spy: Spy())
        let a = dir("2026.09.27-1000", model)
        await model.requestTrash([a]).value
        #expect(model.trashRequest?.plan.trashable == [a])
        #expect(model.trashRequest?.plan.blocked.isEmpty == true)
    }

    @Test func aQueuedTranscriptionBlocksTheSession() async throws {
        try failedTranscription("2026.09.27-1000")
        let spy = Spy()
        let model = await loaded(spy: spy)
        let a = dir("2026.09.27-1000", model)
        model.trashEffects.hasPendingWork = { $0.standardizedFileURL == a.standardizedFileURL }
        await model.requestTrash([a]).value
        #expect(model.trashRequest?.plan.blocked == [TrashPlan.Blocked(dir: a, reason: .pending)])
        await model.confirmTrash(deleteFromMemory: false).value
        #expect(spy.trashed.isEmpty)
    }

    @Test func aTranscriptionQueuedAfterTheSheetBlocksTheMove() async throws {
        try failedTranscription("2026.09.27-1000")
        let spy = Spy()
        let model = await loaded(spy: spy)
        let a = dir("2026.09.27-1000", model)
        await model.requestTrash([a]).value
        #expect(model.trashRequest?.plan.trashable == [a])
        // "Reintentar" queued it while the sheet was up.
        model.trashEffects.hasPendingWork = { _ in true }
        await model.confirmTrash(deleteFromMemory: false).value
        #expect(spy.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.path))
    }
}
