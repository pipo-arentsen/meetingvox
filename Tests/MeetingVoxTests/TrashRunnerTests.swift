import Foundation
import Testing
@testable import MeetingVox

/// Records what the runner asked for, in order. Never touches the real Trash
/// or a Hindsight server: `trash` moves into a temp folder, memory answers
/// from a script.
@MainActor
private final class Harness {
    let root: URL
    let fakeTrash: URL
    private var _events: [String] = []
    var memoryAnswers: [String: HindsightCoordinator.DeleteResult] = [:]
    var trashErrors: Set<String> = []
    var stillBlocked: [String: TrashPlan.BlockReason] = [:]
    /// Blocked from the Nth `recheck` call of that session on (1 = the first).
    var blockedFromCheck: [String: (call: Int, reason: TrashPlan.BlockReason)] = [:]
    private var checks: [String: Int] = [:]

    var events: [String] { _events }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("trash-runner-\(UUID().uuidString)")
        fakeTrash = root.appendingPathComponent(".fake-trash")
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func session(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    func runner() -> TrashRunner {
        TrashRunner(
            deleteFromMemory: { [self] dir in
                _events.append("memory:\(dir.lastPathComponent)")
                return memoryAnswers[dir.lastPathComponent] ?? .deleted
            },
            trash: { [self] dir in
                _events.append("trash:\(dir.lastPathComponent)")
                if trashErrors.contains(dir.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: dir, to: fakeTrash.appendingPathComponent(dir.lastPathComponent))
            },
            recheck: { [self] dir in
                let name = dir.lastPathComponent
                checks[name, default: 0] += 1
                if let later = blockedFromCheck[name], checks[name]! >= later.call { return later.reason }
                return stillBlocked[name]
            }
        )
    }

    func plan(_ dirs: [URL], recording: URL? = nil, sent: Set<String> = []) -> TrashPlan {
        TrashPlan.make(
            sessions: dirs, recordingDir: recording, liveOverlay: { _ in [:] },
            isInMemory: { sent.contains($0.lastPathComponent) }, memoryEnabled: true,
            hasPendingWork: { _ in false }
        )
    }

    /// A v2 sent record and a pending send request, as left by a real send.
    func markInMemory(_ dir: URL) throws {
        try Data("{}".utf8).write(to: dir.appendingPathComponent(SessionFiles.hindsightSent))
        try Data("{}".utf8).write(to: dir.appendingPathComponent(SessionFiles.hindsightRequested))
    }

    func hasMemoryRecords(_ dir: URL) -> Bool {
        exists(dir.appendingPathComponent(SessionFiles.hindsightSent))
            || exists(dir.appendingPathComponent(SessionFiles.hindsightRequested))
    }

    func exists(_ dir: URL) -> Bool { FileManager.default.fileExists(atPath: dir.path) }
}

@MainActor
@Suite struct TrashRunnerTests {
    @Test func trashesEveryTrashableSessionWithoutTouchingMemoryByDefault() async throws {
        let h = try Harness()
        let (a, b) = (try h.session("a"), try h.session("b"))

        let report = await h.runner().run(plan: h.plan([a, b], sent: ["a"]), deleteFromMemory: false)

        #expect(report.trashed == [a, b])
        #expect(h.events == ["trash:a", "trash:b"])
        #expect(!h.exists(a) && !h.exists(b))
    }

    @Test func memoryIsDeletedBeforeTheFolderMoves() async throws {
        let h = try Harness()
        let a = try h.session("a")

        let report = await h.runner().run(plan: h.plan([a], sent: ["a"]), deleteFromMemory: true)

        #expect(h.events == ["memory:a", "trash:a"])
        #expect(report.trashed == [a])
    }

    @Test func aMemoryFailureKeepsTheFolderAndTheRestStillGo() async throws {
        let h = try Harness()
        let (a, b) = (try h.session("a"), try h.session("b"))
        h.memoryAnswers["a"] = .failed("transient (HTTP 503)")

        let report = await h.runner().run(plan: h.plan([a, b], sent: ["a", "b"]), deleteFromMemory: true)

        #expect(report.memoryFailed == [a])
        #expect(report.trashed == [b])
        #expect(h.exists(a))
        #expect(!h.events.contains("trash:a"))
    }

    @Test func aSessionThatNeverReachedMemoryIsTrashedEvenWhenDeletionWasRequested() async throws {
        let h = try Harness()
        let a = try h.session("a")
        h.memoryAnswers["a"] = .notInMemory

        let report = await h.runner().run(plan: h.plan([a]), deleteFromMemory: true)

        #expect(report.trashed == [a])
        #expect(report.memoryFailed.isEmpty)
    }

    @Test func aTrashFailureIsReportedAndTheFolderStays() async throws {
        let h = try Harness()
        let (a, b) = (try h.session("a"), try h.session("b"))
        h.trashErrors = ["a"]

        let report = await h.runner().run(plan: h.plan([a, b]), deleteFromMemory: false)

        #expect(report.trashFailed == [a])
        #expect(report.trashed == [b])
        #expect(h.exists(a))
    }

    @Test func blockedSessionsAreSkippedAndReported() async throws {
        let h = try Harness()
        let (a, b) = (try h.session("a"), try h.session("b"))

        let report = await h.runner().run(plan: h.plan([a, b], recording: b), deleteFromMemory: true)

        #expect(report.trashed == [a])
        #expect(report.blocked == [TrashPlan.Blocked(dir: b, reason: .recording)])
        #expect(h.exists(b))
        #expect(!h.events.contains { $0.hasSuffix(":b") })
    }

    @Test func aSessionThatBecameBusyAfterConfirmingIsSkipped() async throws {
        let h = try Harness()
        let a = try h.session("a")
        h.stillBlocked["a"] = .recording

        let report = await h.runner().run(plan: h.plan([a], sent: ["a"]), deleteFromMemory: true)

        #expect(report.trashed.isEmpty)
        #expect(report.blocked == [TrashPlan.Blocked(dir: a, reason: .recording)])
        #expect(h.events.isEmpty)
        #expect(h.exists(a))
    }

    @Test func theBlockingCheckRunsAgainRightBeforeTheMoveAndKeepsTheSession() async throws {
        let h = try Harness()
        let a = try h.session("a")
        h.blockedFromCheck["a"] = (call: 2, reason: .pending)

        let report = await h.runner().run(plan: h.plan([a], sent: ["a"]), deleteFromMemory: true)

        #expect(h.events == ["memory:a"])
        #expect(report.trashed.isEmpty)
        #expect(report.blocked == [TrashPlan.Blocked(dir: a, reason: .pending)])
        #expect(h.exists(a))
    }

    @Test func aSessionBlockedAfterItsMemoryDeleteNoLongerClaimsToBeInMemory() async throws {
        let h = try Harness()
        let a = try h.session("a")
        try h.markInMemory(a)
        h.blockedFromCheck["a"] = (call: 2, reason: .pending)

        _ = await h.runner().run(plan: h.plan([a], sent: ["a"]), deleteFromMemory: true)

        #expect(h.exists(a))
        #expect(!h.hasMemoryRecords(a))
    }

    @Test func memoryDeletedButTrashFailedForgetsTheMemoryRecordsAndKeepsTheFolder() async throws {
        let h = try Harness()
        let a = try h.session("a")
        try h.markInMemory(a)
        h.trashErrors = ["a"]

        let report = await h.runner().run(plan: h.plan([a], sent: ["a"]), deleteFromMemory: true)

        #expect(report.trashFailed == [a])
        #expect(h.exists(a))
        #expect(!h.hasMemoryRecords(a))
        #expect(h.exists(a.appendingPathComponent(SessionFiles.meta)))
    }

    @Test func aTrashFailureWithoutAMemoryDeleteKeepsTheMemoryRecords() async throws {
        let h = try Harness()
        let a = try h.session("a")
        try h.markInMemory(a)
        h.trashErrors = ["a"]

        _ = await h.runner().run(plan: h.plan([a], sent: ["a"]), deleteFromMemory: false)

        #expect(h.hasMemoryRecords(a))
    }

    @Test func aFailedMemoryDeleteKeepsTheMemoryRecords() async throws {
        let h = try Harness()
        let a = try h.session("a")
        try h.markInMemory(a)
        h.memoryAnswers["a"] = .failed("transient (HTTP 503)")

        _ = await h.runner().run(plan: h.plan([a], sent: ["a"]), deleteFromMemory: true)

        #expect(h.hasMemoryRecords(a))
    }

    @Test func theRecordingFolderIsNeverTrashed() async throws {
        let h = try Harness()
        let a = try h.session("a")

        let report = await h.runner().run(plan: h.plan([a], recording: a), deleteFromMemory: false)

        #expect(h.events.isEmpty)
        #expect(report.trashed.isEmpty)
        #expect(h.exists(a))
    }

    @Test func theSuccessSummaryIsEmptyOnlyWhenNothingHappened() async throws {
        let h = try Harness()
        let report = await h.runner().run(plan: h.plan([]), deleteFromMemory: false)
        #expect(report.isEmpty)
    }
}
