import Foundation

/// Which side of the meeting a track carries. The raw values are the keys of
/// meta.json `files` / `start_offset_ms`.
enum PlaybackTrackID: String, CaseIterable, Sendable {
    /// `mic.caf`: the user.
    case mic
    /// `system.caf`: everyone else.
    case system
}

/// One playable track: its file, where it starts on the session clock and how
/// long it is. `length` 0 = unknown (the file could not be read off the main
/// thread; the player falls back to its own duration once it is built).
struct PlaybackTrackInfo: Equatable, Sendable {
    let id: PlaybackTrackID
    let url: URL
    /// `start_offset_ms` / 1000 is applied by the timeline; this stays in ms as on disk.
    let offsetMs: Int
    let length: TimeInterval

    /// Seconds after the session start at which this track begins (never negative).
    var offset: TimeInterval { Double(max(0, offsetMs)) / 1000 }
    var end: TimeInterval { offset + length }
}

/// Pure mapping from the session clock to each track.
/// Session time `t` is a track's own time `t - offset`: a track that started
/// later waits, one that ended is finished, and there is never a negative
/// position.
struct PlaybackTimeline: Equatable, Sendable {
    let tracks: [PlaybackTrackInfo]

    /// Where a track is for a given session time.
    enum Placement: Equatable {
        /// Not started yet: begins `delay` seconds from now.
        case waiting(delay: TimeInterval)
        case playing(position: TimeInterval)
        case finished
    }

    /// The lead the click-to-seek leaves before a line, so its first word is heard.
    static let lineLead: TimeInterval = 0.5

    init(tracks: [PlaybackTrackInfo]) { self.tracks = tracks }

    var isPlayable: Bool { !tracks.isEmpty }

    /// The latest end over the tracks (offset + length); 0 without tracks.
    var duration: TimeInterval { tracks.map(\.end).max() ?? 0 }

    func has(_ id: PlaybackTrackID) -> Bool { tracks.contains { $0.id == id } }

    func info(_ id: PlaybackTrackID) -> PlaybackTrackInfo? { tracks.first { $0.id == id } }

    /// nil for a track the session does not have.
    func placement(of id: PlaybackTrackID, at t: TimeInterval) -> Placement? {
        guard let track = info(id) else { return nil }
        let local = t - track.offset
        if local < 0 { return .waiting(delay: -local) }
        if track.length > 0, local >= track.length { return .finished }
        return .playing(position: local)
    }

    /// `t` kept inside `0...duration`.
    func clamped(_ t: TimeInterval) -> TimeInterval { min(max(0, t), duration) }

    // MARK: - Lines

    /// Where a click on a line seeks: its start minus `lineLead`, never before 0.
    static func seekTime(forLineStartMs startMs: Int) -> TimeInterval {
        max(0, Double(startMs) / 1000 - lineLead)
    }

    /// `TranscriptViewLine.id` of the last line that started at or before `t`;
    /// nil before the first one. `lines` are in time order.
    static func currentLine(in lines: [TranscriptViewLine], at t: TimeInterval) -> Int? {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if Double(lines[mid].startMs) / 1000 <= t { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : lines[low - 1].id
    }
}
