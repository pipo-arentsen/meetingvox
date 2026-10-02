import AVFoundation
import Foundation

/// Which tracks a session has and where each starts, read from meta.json.
/// A reader of its own on purpose: the transcription coordinator's
/// private `SessionMeta` stays untouched. Everything here only reads: the
/// `.caf` files are opened for reading and never modified.
enum SessionTracks {
    /// What meta.json says about one track.
    struct Ref: Equatable, Sendable {
        let id: PlaybackTrackID
        let file: String
        let offsetMs: Int
    }

    /// The tracks listed in `files`, mic first. A missing offset is 0 (sessions
    /// from before offsets were captured), a negative one too. A file name that
    /// is not a bare name is dropped: meta.json is ours, but nothing it says is
    /// followed out of the session folder.
    static func parse(metaJSON: Data) -> [Ref] {
        guard let json = (try? JSONSerialization.jsonObject(with: metaJSON)) as? [String: Any],
              let files = json["files"] as? [String: Any]
        else { return [] }
        let offsets = json["start_offset_ms"] as? [String: Any] ?? [:]
        return PlaybackTrackID.allCases.compactMap { id in
            guard let file = files[id.rawValue] as? String, isBareName(file) else { return nil }
            let offset = (offsets[id.rawValue] as? NSNumber)?.intValue ?? 0
            return Ref(id: id, file: file, offsetMs: max(0, offset))
        }
    }

    /// The session's playable tracks: those listed in meta.json whose file is
    /// on disk, with their length. Off the main thread (`length` reads the
    /// file header); `length` is injectable so tests need no audio.
    static func info(in dir: URL, length: (URL) -> TimeInterval = audioLength) -> [PlaybackTrackInfo] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.meta)) else { return [] }
        return parse(metaJSON: data).compactMap { ref in
            let url = dir.appendingPathComponent(ref.file)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return PlaybackTrackInfo(id: ref.id, url: url, offsetMs: ref.offsetMs, length: length(url))
        }
    }

    /// Seconds of audio in the file, 0 when it cannot be read (the player's
    /// own duration stands in later). Read-only.
    static func audioLength(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func isBareName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }
}
