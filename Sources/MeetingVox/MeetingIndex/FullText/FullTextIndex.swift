import Foundation

/// The in-memory full-text index behind the list search.
///
/// One `FullTextDocument` per session, cached by the stamp (mtime + size) of
/// `transcript.json` and `minuta.md`: a rescan re-reads only a file whose
/// stamp changed and forgets sessions that left the list. Nothing is written
/// to disk. An actor, so the reads and every keystroke's scan stay off the
/// main thread; the window clears it on close (`clear()`) and the next scan
/// rebuilds it.
actor FullTextIndex {
    struct Result: Sendable, Equatable {
        /// Sessions whose metadata ∪ transcript ∪ minutes satisfy every token.
        let matches: Set<URL>
        /// Why each transcript/minutes-only match matched; metadata-only
        /// matches have no entry (no snippet needed).
        let hits: [URL: SearchHit]

        static let empty = Result(matches: [], hits: [:])
    }

    private struct Cached {
        let transcriptStamp: SessionDetailData.FileStamp?
        let minutesStamp: SessionDetailData.FileStamp?
        let document: FullTextDocument
    }

    private var cache: [URL: Cached] = [:]
    /// Sessions (re)read so far; tests watch it to prove an unchanged file is not read again.
    private(set) var loadCount = 0
    var cachedCount: Int { cache.count }

    /// Brings the cache in line with `entries`: reads new or changed
    /// sessions, keeps the rest, drops the gone. A cancelled refresh stops
    /// early and leaves what it already read (still consistent).
    func refresh(_ entries: [MeetingEntry]) {
        var keep = Set<URL>()
        for entry in entries where entry.hasTranscript || entry.hasMinutes {
            if Task.isCancelled { return }
            keep.insert(entry.dir)
            let transcriptURL = entry.dir.appendingPathComponent(SessionFiles.transcriptJSON)
            let minutesURL = entry.dir.appendingPathComponent(SessionFiles.minutes)
            // Taken before reading: a write racing the read leaves the older
            // stamp, so the next refresh reads again.
            let transcriptStamp = SessionDetailData.FileStamp(transcriptURL)
            let minutesStamp = SessionDetailData.FileStamp(minutesURL)
            if let cached = cache[entry.dir],
               cached.transcriptStamp == transcriptStamp, cached.minutesStamp == minutesStamp {
                continue
            }
            let lines = transcriptStamp == nil ? nil : TranscriptViewLines.load(from: entry.dir)
            let minutes = minutesStamp == nil ? nil : (try? Data(contentsOf: minutesURL)).map { String(decoding: $0, as: UTF8.self) }
            cache[entry.dir] = Cached(
                transcriptStamp: transcriptStamp, minutesStamp: minutesStamp,
                document: .make(transcript: lines, minutes: minutes)
            )
            loadCount += 1
        }
        for dir in cache.keys where !keep.contains(dir) { cache[dir] = nil }
    }

    /// Which of `entries` match `query`, and the snippet for the ones that
    /// matched through transcript/minutes text. An entry not cached is
    /// searched by its metadata alone.
    func search(query: String, entries: [MeetingEntry]) -> Result {
        let tokens = SearchMatcher.tokens(of: query)
        guard !tokens.isEmpty else { return .empty }
        var matches = Set<URL>()
        var hits: [URL: SearchHit] = [:]
        for entry in entries {
            if Task.isCancelled { break }
            let document = cache[entry.dir]?.document ?? .empty
            switch SearchMatcher.match(tokens: tokens, metadata: MeetingFilter.haystackText(entry), document: document) {
            case .none: continue
            case .metadata: matches.insert(entry.dir)
            case .hit(let hit):
                matches.insert(entry.dir)
                hits[entry.dir] = hit
            }
        }
        return Result(matches: matches, hits: hits)
    }

    /// Forget everything (the window closed); searches find nothing until the next `refresh`.
    func clear() {
        cache.removeAll()
    }
}
