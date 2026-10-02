import Foundation

/// What a trash run did, session by session.
struct TrashReport: Equatable, Sendable {
    /// Moved to the Trash.
    var trashed: [URL] = []
    /// Skipped: recording, or a stage working on it (now or when confirmed).
    var blocked: [TrashPlan.Blocked] = []
    /// Memory deletion was asked for and failed: the folder was kept.
    var memoryFailed: [URL] = []
    /// The move to the Trash failed: the folder is where it was.
    var trashFailed: [URL] = []

    var isEmpty: Bool { trashed.isEmpty && blocked.isEmpty && memoryFailed.isEmpty && trashFailed.isEmpty }
    var hasProblems: Bool { !memoryFailed.isEmpty || !trashFailed.isEmpty }
}

/// Executes a confirmed `TrashPlan`. Per session: re-check that nothing
/// started on it since the sheet was shown, delete it from memory first when
/// that was asked for (a failure keeps the folder, so the user can try again
/// with the document still reachable), re-check once more (the memory delete
/// is a network await, so work may have started meanwhile), then move the
/// folder to the Trash. Never `removeItem`: the folder stays recoverable from
/// the macOS Trash.
///
/// When the document was deleted from memory but the folder stays (blocked in
/// that last re-check, or the move failed), the session's `hindsight.json` and
/// `hindsight.solicitado` are removed so it no longer claims to be "En memoria".
///
/// Seams only: the real ones are `HindsightCoordinator.deleteFromMemory` and
/// `FileManager.trashItem`; tests pass fakes and never touch either.
@MainActor
struct TrashRunner {
    var deleteFromMemory: (URL) async -> HindsightCoordinator.DeleteResult
    var trash: (URL) throws -> Void
    /// The session is blocked right now (live state, not the plan's snapshot).
    var recheck: (URL) async -> TrashPlan.BlockReason?
    /// The folder stays after its document was deleted from memory: drop the
    /// records that say it is there. Real by default (tests use temp folders).
    var forgetMemory: (URL) -> Void = TrashRunner.removeMemoryRecords

    func run(plan: TrashPlan, deleteFromMemory wantsMemoryDelete: Bool) async -> TrashReport {
        var report = TrashReport(blocked: plan.blocked)
        for dir in plan.trashable {
            if let reason = await recheck(dir) {
                report.blocked.append(TrashPlan.Blocked(dir: dir, reason: reason))
                continue
            }
            var memoryDeleted = false
            if wantsMemoryDelete {
                // Only a failure holds the folder back: `.notInMemory` means
                // there is nothing to delete.
                switch await deleteFromMemory(dir) {
                case .failed:
                    report.memoryFailed.append(dir)
                    continue
                case .deleted:
                    memoryDeleted = true
                case .notInMemory:
                    break
                }
                // The await above is where work can start on the session.
                if let reason = await recheck(dir) {
                    if memoryDeleted { forgetMemory(dir) }
                    report.blocked.append(TrashPlan.Blocked(dir: dir, reason: reason))
                    continue
                }
            }
            do {
                try trash(dir)
                report.trashed.append(dir)
            } catch {
                FileHandle.standardError.write(Data(
                    "trash: could not move \(dir.lastPathComponent) to the Trash: \(error)\n".utf8
                ))
                report.trashFailed.append(dir)
                if memoryDeleted { forgetMemory(dir) }
            }
        }
        return report
    }

    /// Removes `hindsight.json` and `hindsight.solicitado` (nothing else) and
    /// logs one line to stderr.
    nonisolated static func removeMemoryRecords(_ dir: URL) {
        for name in [SessionFiles.hindsightSent, SessionFiles.hindsightRequested] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        FileHandle.standardError.write(Data(
            "trash: \(dir.lastPathComponent) was deleted from memory but kept; cleared its memory records\n".utf8
        ))
    }
}
