import Foundation

/// Reads sessions under a recordings root for the main window. An
/// `actor` only because disk reads shouldn't block the main thread; it holds
/// no state — each call is a fresh read.
actor MeetingIndex {
    /// Every session, cheaply: meta.json, resumen.json and marker checks.
    func scan(root: URL) -> [MeetingEntry] {
        SessionFiles.sessions(in: root).map(MeetingEntry.load)
    }

    /// Memory facts (each reads and hashes a transcript) — only for the
    /// sessions the window shows.
    func facts(for dirs: [URL], options: HindsightFacts.Options) -> [URL: HindsightFacts] {
        Dictionary(dirs.map { ($0, HindsightFacts.read($0, options)) }, uniquingKeysWith: { first, _ in first })
    }
}
