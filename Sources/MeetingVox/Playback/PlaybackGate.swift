import Foundation

/// Whether a session may be played right now. Pure.
///
/// The folder being recorded is never playable (it has no `meta.json` yet and
/// its files are still growing). Any other session pauses while ANY recording
/// runs, even when the tap excludes MeetingVox's own audio: the speakers would
/// still be picked up by the microphone and leak into `mic.caf`.
enum PlaybackGate: Equatable, Sendable {
    case allowed
    /// The session has no playable track.
    case noAudio
    /// A recording runs (whatever its tap excludes).
    case pausedWhileRecording
    /// This is the session being recorded.
    case thisSessionRecording

    var canPlay: Bool { self == .allowed }

    /// `excludesSelf` is accepted for diagnostics only; it never changes the result.
    ///
    /// Order matters: the recorded folder has no `meta.json` yet, so it would
    /// look like "no audio" if that were checked first.
    static func decide(session: URL?, hasTracks: Bool, recordingDir: URL?, excludesSelf: Bool) -> PlaybackGate {
        if let session, let recordingDir, same(session, recordingDir) { return .thisSessionRecording }
        if !hasTracks { return .noAudio }
        if recordingDir != nil { return .pausedWhileRecording }
        return .allowed
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }
}
