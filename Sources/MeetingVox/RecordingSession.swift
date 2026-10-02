import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
///
/// A track that can't record (mic permission denied, no input device, tap
/// failure) doesn't cost the meeting: the other track records alone, the
/// user is notified once, and meta.json lists only the tracks with a file.
/// Only both tracks failing fails the session.
final class RecordingSession {
    enum StartError: Error, CustomStringConvertible {
        case noTracks(mic: Error, system: Error)

        var description: String {
            switch self {
            case .noTracks(let mic, let system): return Textos.Errores.sinPistas(mic: mic, system: system)
            }
        }
    }

    let dir: URL
    let startedAt = Date()
    /// Template for this session's automatic minutes, chosen in the meeting
    /// prompt or the menu while recording; written to meta.json at stop
    /// (`minutes_template`). Nil = the config default applies.
    var minutesTemplate: String?
    /// The meeting app rule id (see `MeetingApp`) this session was started
    /// from, when started from the meeting prompt; written to meta.json at
    /// stop (`meeting_app`). Nil for a manual recording.
    var meetingApp: String?
    /// The mic stopped hearing (or hears again): the pill's silent-mic face.
    /// Called on the capture queues; forwarded to a `MicSignalReporting` mic at
    /// `start()`, so set it before. Not called for a mic that cannot report
    /// (the VPIO engine).
    var onMicSignal: (@Sendable (MicSignal) -> Void)?

    private let mic: MicRecording
    private let system: TrackRecording
    private let notify: @Sendable (String, String) -> Void
    private var micStarted = false
    private var systemStarted = false
    private var stopped = false
    /// The mic dropped out after `start` (permission answered "no"): its meter
    /// shows "—". Set on any queue.
    private let micLost = LostFlag()

    /// One snapshot of both tracks' peaks since the last call (swap-to-zero:
    /// call it from ONE poller). A track that never started, failed, was lost,
    /// is not metered (the VPIO mic) or whose session stopped is `.unavailable`.
    func levels() -> LevelSnapshot {
        LevelSnapshot(
            mic: micStarted && !micLost.isSet ? reading(of: mic) : .unavailable,
            system: systemStarted ? reading(of: system) : .unavailable)
    }

    private func reading(of track: TrackRecording) -> TrackLevel {
        guard !stopped, let metered = track as? MeteredTrack else { return .unavailable }
        return .sample(metered.level.sample())
    }

    /// True when the system tap that is recording excludes this process, so
    /// playback inside MeetingVox cannot leak into `system.caf`. False when the
    /// system track did not start, or its tap could not exclude us.
    var systemTapExcludesSelf: Bool {
        systemStarted && ((system as? SelfExcludingTap)?.excludesSelf ?? false)
    }

    private static let micFile = "mic.caf"
    private static let systemFile = "system.caf"

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet. The mic recorder defaults to
    /// the config-selected backend (AVCaptureSession; AVAudioEngine only for
    /// voice processing, see `MicBackend`), chosen once here.
    init(root: URL,
         mic: MicRecording = MicBackend.current().makeRecorder(),
         system: TrackRecording = SystemAudioRecorder(),
         notify: @escaping @Sendable (String, String) -> Void = { notifyUser(title: $0, body: $1) }) throws {
        self.mic = mic
        self.system = system
        self.notify = notify
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Start both tracks: mic first, then the system tap (the order
    /// `quill diag` validated with the capture-session mic on a Bluetooth
    /// headset; `start_offset_ms` comes from each track's first buffer, so
    /// order doesn't affect alignment). Throws only if neither track starts.
    func start() throws {
        let micNotice = NotifyOnce()
        let notify = self.notify
        let micLost = self.micLost
        (mic as? MicSignalReporting)?.onSignalChange = onMicSignal
        // The mic can also drop out after `start` returns (permission prompt
        // answered "no"): same notice, at most once.
        mic.onUnavailable = { error in
            micLost.set()
            Self.log("mic unavailable, recording system audio only: \(error)")
            if micNotice.claim() { notify(Textos.Notificacion.sinMicrofono, "\(error)") }
        }

        var micError: Error?
        do {
            try mic.start(writingTo: dir.appendingPathComponent(Self.micFile))
            micStarted = true
        } catch {
            micError = error
        }

        do {
            try system.start(writingTo: dir.appendingPathComponent(Self.systemFile))
            systemStarted = true
        } catch {
            if let micError {
                throw StartError.noTracks(mic: micError, system: error)
            }
            Self.log("system audio failed, recording mic only: \(error)")
            notify(Textos.Notificacion.sinAudioSistema, "\(error)")
        }

        if let micError {
            Self.log("mic failed, recording system audio only: \(micError)")
            if micNotice.claim() { notify(Textos.Notificacion.sinMicrofono, "\(micError)") }
        }
    }

    /// Stop both tracks and write meta.json (only tracks that have a file).
    func stop() {
        stopped = true
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        var starts: [String: Date] = [:]
        var files: [String: String] = [:]
        if micStarted, fileExists(Self.micFile) {
            files["mic"] = Self.micFile
            starts["mic"] = mic.firstBufferAt ?? startedAt
        }
        if systemStarted, fileExists(Self.systemFile) {
            files["system"] = Self.systemFile
            starts["system"] = system.firstBufferAt ?? startedAt
        }

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let earliest = starts.values.min() ?? startedAt
        var meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": files,
            "start_offset_ms": starts.mapValues { Int(($0.timeIntervalSince(earliest) * 1000).rounded()) },
        ]
        if let minutesTemplate {
            meta[SessionFiles.metaMinutesTemplateKey] = minutesTemplate
        }
        if let meetingApp {
            meta[SessionFiles.metaMeetingAppKey] = meetingApp
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Set once from any queue, read from main.
private final class LostFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// True the first time only; safe from any queue.
private final class NotifyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
