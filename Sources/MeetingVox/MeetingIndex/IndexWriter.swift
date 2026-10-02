import Foundation

extension Notification.Name {
    /// Posted (on main) after `indice.md` is regenerated, so an open
    /// main window can refresh without polling.
    static let meetingVoxMeetingIndexDidChange = AppIdentity.notificationName("meetingIndexDidChange")
}

/// Writes `indice.md` at the recordings root, atomically and as a whole
/// (never incrementally). `SummaryCoordinator` is the sole caller (see
/// design), so there is never more than one writer at a time.
enum IndexWriter {
    /// Scan every session under `root`, render `indice.md`, and write it.
    /// Best-effort: a write failure is logged to stderr and never thrown —
    /// regenerating the index must not block the summary pipeline.
    static func regenerate(root: URL) {
        let entries = SessionFiles.sessions(in: root).map(MeetingEntry.load)
        let markdown = IndexRenderer.render(entries: entries)
        do {
            try markdown.data(using: .utf8)?.write(to: root.appendingPathComponent(SessionFiles.index), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("could not write \(SessionFiles.index): \(error)\n".utf8))
        }
    }
}
