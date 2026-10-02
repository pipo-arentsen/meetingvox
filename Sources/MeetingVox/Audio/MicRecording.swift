@preconcurrency import AVFoundation
import Foundation

// MARK: - Shared recorder interfaces

/// One audio track of a recording (mic or system). `RecordingSession` only
/// needs this much, which also lets tests drive it with fakes.
protocol TrackRecording: AnyObject {
    var isRecording: Bool { get }
    /// Wall-clock time of the first buffer written — the track's true start,
    /// used for `start_offset_ms` alignment with the other track.
    var firstBufferAt: Date? { get }

    func start(writingTo url: URL) throws
    func stop()
}

extension SystemAudioRecorder: TrackRecording {}

/// A mic recorder. Both implementations write the same file: AAC-in-CAF,
/// 48 kHz mono, written incrementally (CAF needs no finalization, so a crash
/// loses nothing already written). Recorder-specific diagnostics (`diagEvent`)
/// are not part of this protocol; `quill diag` wires them per concrete type.
protocol MicRecording: TrackRecording {
    /// Diagnostics only (`quill diag`): receives every captured buffer. Set
    /// before `start`, never after.
    var diagBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    /// Called (on any queue) when the mic becomes unavailable *after*
    /// `start` returned — e.g. the permission prompt answered "no", or the
    /// capture session could not be configured once permission arrived. Set
    /// before `start`.
    var onUnavailable: (@Sendable (Error) -> Void)? { get set }
}

/// Which mic capture implementation a recording uses.
enum MicBackend: Equatable {
    /// `AVCaptureSession` (`CaptureMicRecorder`): the default. Binds to the
    /// input device only, so it leaves a Bluetooth headset's output alone.
    case capture
    /// `AVAudioEngine` (`MicRecorder`): only for voice processing (VPIO),
    /// which needs the duplex engine graph.
    case engine

    static func forConfig(voiceProcessing: Bool) -> MicBackend {
        voiceProcessing ? .engine : .capture
    }

    static func current() -> MicBackend { forConfig(voiceProcessing: Config.micVoiceProcessing()) }

    func makeRecorder() -> MicRecording {
        switch self {
        case .capture: return CaptureMicRecorder()
        case .engine: return MicRecorder()
        }
    }
}

/// Microphone TCC permission.
enum MicPermission {
    /// Asks for mic access if it was never decided, without waiting. Called
    /// at launch so the prompt shows up before the first meeting instead of
    /// in the middle of starting one.
    static func requestIfUndetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            FileHandle.standardError.write(Data("mic permission \(granted ? "granted" : "denied")\n".utf8))
        }
    }

    enum Decision: Equatable {
        case alreadyGranted
        case ask
        /// Denied or restricted: the system never asks again, only Settings can change it.
        case denied
    }

    static func decision(for status: AVAuthorizationStatus) -> Decision {
        switch status {
        case .authorized: return .alreadyGranted
        case .notDetermined: return .ask
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// The onboarding "Permitir": asks if never decided and returns once the
    /// user answered, so the next request starts after this one's callback.
    /// `true` when the microphone is (now) authorized.
    static func request() async -> Bool {
        switch decision(for: AVCaptureDevice.authorizationStatus(for: .audio)) {
        case .alreadyGranted: return true
        case .denied: return false
        case .ask: return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }
}

/// Hands one buffer to an `AVAudioConverter` input block, then reports
/// "no data now". Only used inside a single synchronous `convert` call.
final class OneShotFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

// MARK: - Pure policies (unit-tested)

/// Silence padding that keeps the mic track aligned with the wall clock (and
/// hence with the system track) across capture gaps.
enum MicTimeline {
    /// Smallest gap worth padding; below this it is buffer-delivery jitter.
    static let minimumGap: TimeInterval = 0.25
    /// How far the sample-timestamp timeline may run ahead of the wall clock.
    static let wallClockTolerance: TimeInterval = 0.25
    /// Behind the wall clock by more than this, the sample timestamps are
    /// considered bogus (stale clock after a device switch) and ignored.
    static let maxMediaLag: TimeInterval = 1

    /// Frames of silence to write before a buffer of `incomingFrames`
    /// arriving `elapsed` seconds after the first buffer, given
    /// `framesWritten` so far. The incoming buffer is assumed to *end* now,
    /// so its own frames are subtracted from the expected position.
    static func silenceFrames(elapsed: TimeInterval, framesWritten: Int64, incomingFrames: Int64,
                              sampleRate: Double, minimumGap: TimeInterval = minimumGap) -> Int64 {
        let expected = Int64(elapsed * sampleRate) - incomingFrames
        let gap = expected - framesWritten
        return gap > Int64(minimumGap * sampleRate) ? gap : 0
    }

    /// Elapsed time since the first buffer, used to size a gap. Sample
    /// timestamps (`media`) are preferred — a buffer merely delivered late
    /// is not lost audio — but never trusted beyond the wall clock: at most
    /// `wall + tolerance`, and ignored when they lag it by more than
    /// `maxLag` (a timestamp converted with the wrong clock).
    static func gapElapsed(media: TimeInterval?, wall: TimeInterval,
                           tolerance: TimeInterval = wallClockTolerance,
                           maxLag: TimeInterval = maxMediaLag) -> TimeInterval {
        guard let media, media.isFinite, media >= wall - maxLag else { return wall }
        return min(media, wall + tolerance)
    }
}

/// At most one action per `minimumInterval`. Used for default-input
/// switches, so a flapping default device can't cause a switch loop.
struct RestartLimiter {
    let minimumInterval: TimeInterval
    private(set) var lastRestart: TimeInterval?

    init(minimumInterval: TimeInterval = 5) {
        self.minimumInterval = minimumInterval
    }

    /// True (and records `now`) if a restart may happen at `now`.
    mutating func allow(at now: TimeInterval) -> Bool {
        if let lastRestart, now - lastRestart < minimumInterval { return false }
        lastRestart = now
        return true
    }
}

/// Exponential backoff for recovery restarts (watchdog, runtime error,
/// unexpected stop). Each full restart reopens the mic — on a Bluetooth
/// headset an A2DP <-> HFP cycle that cuts the user's playback — so a mic
/// that stays broken must not be hammered. The first restart is immediate;
/// the next ones wait `delays` (5, 10, 20, 40 s, then every 60 s). The
/// schedule resets once audio has flowed for `healthyReset` seconds.
struct RestartBackoff {
    static let delays: [TimeInterval] = [5, 10, 20, 40, 60]

    let healthyReset: TimeInterval
    /// A pause in audio longer than this breaks the healthy streak.
    let maxAudioPause: TimeInterval
    private(set) var restarts = 0
    private var lastRestart: TimeInterval?
    private var healthySince: TimeInterval?
    private var lastAudio: TimeInterval?

    init(healthyReset: TimeInterval = 30, maxAudioPause: TimeInterval = 1) {
        self.healthyReset = healthyReset
        self.maxAudioPause = maxAudioPause
    }

    /// Wait required after the last restart before the next one.
    var currentDelay: TimeInterval {
        restarts == 0 ? 0 : Self.delays[min(restarts, Self.delays.count) - 1]
    }

    /// True (and records the restart) if a restart may happen at `now`.
    mutating func allow(at now: TimeInterval) -> Bool {
        if let lastRestart, now - lastRestart < currentDelay { return false }
        lastRestart = now
        restarts += 1
        healthySince = nil
        return true
    }

    /// Audio was written at `now`.
    mutating func noteAudio(at now: TimeInterval) {
        if let lastAudio, now - lastAudio > maxAudioPause { healthySince = nil }
        lastAudio = now
        let since = healthySince ?? now
        healthySince = since
        if restarts > 0, now - since >= healthyReset {
            restarts = 0
            lastRestart = nil
        }
    }
}

/// Detects a mic that delivers buffers but no signal (digital zeros, e.g. a
/// Bluetooth HFP link that never came up). Times are seconds since the
/// recording started (monotonic).
struct DeadMicDetector {
    enum Event: Equatable {
        /// Peak stayed at or below the threshold for `silentFor` seconds.
        /// Emitted once per episode.
        case dead(silentFor: TimeInterval)
        /// Signal is back after a `.dead` episode.
        case recovered
    }

    let threshold: Float
    let deadAfter: TimeInterval
    /// The HFP link can deliver a burst of zeros on start; ignore it.
    let startupGrace: TimeInterval

    private var silentSince: TimeInterval?
    private(set) var inDeadEpisode = false

    init(threshold: Float = 1e-4, deadAfter: TimeInterval = 10, startupGrace: TimeInterval = 3) {
        self.threshold = threshold
        self.deadAfter = deadAfter
        self.startupGrace = startupGrace
    }

    mutating func observe(peak: Float, at time: TimeInterval) -> Event? {
        if peak > threshold {
            silentSince = nil
            if inDeadEpisode {
                inDeadEpisode = false
                return .recovered
            }
            return nil
        }
        guard time >= startupGrace else { return nil }
        let since = silentSince ?? time
        silentSince = since
        if !inDeadEpisode, time - since > deadAfter {
            inDeadEpisode = true
            return .dead(silentFor: time - since)
        }
        return nil
    }
}

/// Health bookkeeping of the mic's sample path: when audio was last
/// *written* (drives the watchdog and stall detection) and whether the mic
/// is dead. A buffer that arrives but can't be converted counts as silence,
/// so a format the converter rejects still ends up restarted and reported.
/// Times are seconds since the recording started.
struct MicHealthMonitor {
    /// A write pause longer than this is checked for a gap to pad.
    static let stallThreshold: TimeInterval = 0.5
    /// Without writes for longer than this, the watchdog feeds silence to
    /// the dead-mic detector.
    static let silentTick: TimeInterval = 1

    private(set) var lastWriteAt: TimeInterval
    private(set) var detector: DeadMicDetector
    /// The user was told about a dead mic this recording; later episodes
    /// only log.
    private(set) var hasNotified = false

    init(detector: DeadMicDetector = DeadMicDetector(), now: TimeInterval = 0) {
        self.detector = detector
        lastWriteAt = now
    }

    func isStalled(at time: TimeInterval) -> Bool {
        time - lastWriteAt > Self.stallThreshold
    }

    mutating func written(peak: Float, at time: TimeInterval) -> DeadMicDetector.Event? {
        lastWriteAt = time
        return detector.observe(peak: peak, at: time)
    }

    mutating func conversionFailed(at time: TimeInterval) -> DeadMicDetector.Event? {
        detector.observe(peak: 0, at: time)
    }

    /// Watchdog tick: how long since the last write, and a dead-mic event
    /// if no audio at all counts as long enough silence.
    mutating func tick(at time: TimeInterval) -> (silentFor: TimeInterval, event: DeadMicDetector.Event?) {
        let silentFor = time - lastWriteAt
        let event = silentFor > Self.silentTick ? detector.observe(peak: 0, at: time) : nil
        return (silentFor, event)
    }

    /// After a restart / switch / interruption end: a fresh watchdog window.
    mutating func resync(at time: TimeInterval) {
        lastWriteAt = time
    }

    /// True for the first `.dead` of the recording only.
    mutating func shouldNotify(_ event: DeadMicDetector.Event) -> Bool {
        guard case .dead = event, !hasNotified else { return false }
        hasNotified = true
        return true
    }
}
