import Foundation
import Testing
@testable import MeetingVox

@Suite struct TrashPlanTests {
    private let root = URL(fileURLWithPath: "/rec", isDirectory: true)
    private func dir(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    private func make(
        _ names: [String], recording: String? = nil, live: [String: LiveStages] = [:],
        sent: Set<String> = [], memoryEnabled: Bool = true, pending: Set<String> = []
    ) -> TrashPlan {
        TrashPlan.make(
            sessions: names.map(dir), recordingDir: recording.map(dir),
            liveOverlay: { live[$0] ?? [:] },
            isInMemory: { sent.contains($0.lastPathComponent) }, memoryEnabled: memoryEnabled,
            hasPendingWork: { pending.contains($0.lastPathComponent) }
        )
    }

    @Test func anIdleSessionIsTrashable() {
        let plan = make(["a"])
        #expect(plan.trashable == [dir("a")])
        #expect(plan.blocked.isEmpty)
    }

    @Test func theRecordingFolderIsBlocked() {
        let plan = make(["a", "b"], recording: "b")
        #expect(plan.trashable == [dir("a")])
        #expect(plan.blocked.map(\.dir) == [dir("b")])
        #expect(plan.blocked.first?.reason == .recording)
    }

    @Test func theRecordingFolderMatchesDespiteATrailingSlashOrDotSegment() {
        let plan = TrashPlan.make(
            sessions: [dir("a")], recordingDir: URL(fileURLWithPath: "/rec/./a/"),
            liveOverlay: { _ in [:] }, isInMemory: { _ in false }, memoryEnabled: true,
            hasPendingWork: { _ in false }
        )
        #expect(plan.trashable.isEmpty)
    }

    @Test(arguments: [Notice.Stage.transcription, .minutes, .summary, .memory])
    func aLiveStageBlocksTheSession(stage: Notice.Stage) {
        let plan = make(["a"], live: ["a": [stage: .running]])
        #expect(plan.blocked.first?.reason == .working(stage))
    }

    @Test func aStageWaitingToRetryBlocksToo() {
        let plan = make(["a"], live: ["a": [.minutes: .waitingRetry]])
        #expect(plan.blocked.first?.reason == .working(.minutes))
    }

    @Test func aStageWorkingOnAnotherFolderDoesNotBlock() {
        let plan = make(["a", "b"], live: ["b": [.summary: .running]])
        #expect(plan.trashable == [dir("a")])
        #expect(plan.blocked.map(\.dir) == [dir("b")])
    }

    @Test func recordingWinsOverAWorkingStage() {
        let plan = make(["a"], recording: "a", live: ["a": [.transcription: .running]])
        #expect(plan.blocked.first?.reason == .recording)
    }

    @Test func offersMemoryDeleteWhenATrashableSessionWasSentAndTheIntegrationIsOn() {
        #expect(make(["a", "b"], sent: ["b"]).offersMemoryDelete)
    }

    @Test func doesNotOfferMemoryDeleteWithNothingSentOrTheIntegrationOff() {
        #expect(!make(["a"]).offersMemoryDelete)
        #expect(!make(["a"], sent: ["a"], memoryEnabled: false).offersMemoryDelete)
    }

    @Test func aBlockedSentSessionDoesNotOfferMemoryDelete() {
        #expect(!make(["a"], recording: "a", sent: ["a"]).offersMemoryDelete)
    }

    @Test func anEmptySelectionIsAnEmptyPlan() {
        let plan = make([])
        #expect(plan.trashable.isEmpty && plan.blocked.isEmpty && !plan.offersMemoryDelete)
    }

    @Test func keepsTheSelectionOrder() {
        #expect(make(["c", "a", "b"]).trashable == [dir("c"), dir("a"), dir("b")])
    }

    @Test func theSheetCopyPluralizesAndNamesEveryReason() {
        #expect(Textos.Papelera.titulo(1) == "¿Mover 1 reunión a la Papelera?")
        #expect(Textos.Papelera.titulo(3) == "¿Mover 3 reuniones a la Papelera?")
        #expect(Textos.Papelera.detalle(1).contains("recuperarla"))
        #expect(Textos.Papelera.detalle(2).contains("recuperarlas"))
        let reasons: [TrashPlan.BlockReason] = [
            .recording, .working(.transcription), .working(.minutes), .working(.summary), .working(.memory),
            .pending,
        ]
        #expect(Set(reasons.map(Textos.Papelera.motivo)).count == reasons.count)
    }

    // MARK: - Pending work on disk

    @Test func pendingWorkOnDiskBlocksTheSession() {
        let plan = make(["a", "b"], pending: ["b"])
        #expect(plan.trashable == [dir("a")])
        #expect(plan.blocked == [TrashPlan.Blocked(dir: dir("b"), reason: .pending)])
    }

    @Test func recordingAndLiveStagesWinOverPendingWork() {
        #expect(make(["a"], recording: "a", pending: ["a"]).blocked.first?.reason == .recording)
        #expect(make(["a"], live: ["a": [.summary: .running]], pending: ["a"]).blocked.first?.reason == .working(.summary))
    }

    @Test(arguments: [
        SessionFiles.minutesPending, SessionFiles.summaryPending, SessionFiles.tasksPending, SessionFiles.hindsightRequested,
    ])
    func eachPendingMarkerOnDiskCountsAsPendingWork(marker: String) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trash-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("{}".utf8).write(to: tmp.appendingPathComponent(SessionFiles.transcriptJSON))
        #expect(!TrashPlan.hasPendingWorkOnDisk(tmp))
        try Data().write(to: tmp.appendingPathComponent(marker))
        #expect(TrashPlan.hasPendingWorkOnDisk(tmp))
    }

    @Test func aMissingTranscriptIsNotOwedWorkOnDisk() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trash-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("{}".utf8).write(to: tmp.appendingPathComponent(SessionFiles.meta))
        // A failed transcription looks exactly like this: trashable.
        #expect(!TrashPlan.hasPendingWorkOnDisk(tmp))
    }
}
