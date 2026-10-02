import Foundation
import Observation

/// The player of one session (R-B.2 to B.4, B.6, B.7): two tracks on one
/// device clock, scrub, speed, per-track volume and mute, and the recording
/// gate. `@MainActor @Observable` over seams (`makeTrack`, `ticker`,
/// `recordingState`) so every rule is tested without an audio device.
///
/// **Clock.** Playing anchors `(deviceStart, t0)`; session time is
/// `t = t0 + (deviceNow - deviceStart) * rate`, read from the first player's
/// `deviceCurrentTime` (all players share it). Each track is scheduled with
/// `play(atTime:)` at `base + delay`, where a track that starts later than `t0`
/// waits. A track more than 50 ms off the timeline is resynced, at most once
/// every 2 s and never in the first 2 s.
///
/// Players are built at the first Play, not on `show`, so selecting sessions
/// never opens a file. Nothing is remembered between sessions: showing
/// another folder resets speed, mutes and volumes.
@MainActor
@Observable
final class PlaybackController {
    /// Lead before the first audible sample, so both tracks can be scheduled.
    static let startLead: TimeInterval = 0.05
    static let driftThreshold: TimeInterval = 0.05
    static let resyncInterval: TimeInterval = 2
    static let tickInterval: TimeInterval = 0.1
    static let rateRange: ClosedRange<Double> = 0.5...2.0

    /// The folder shown (nil = none).
    private(set) var dir: URL?
    /// What can be played, after the players' own durations filled any gaps.
    private(set) var timeline = PlaybackTimeline(tracks: [])
    /// Session time, in seconds. Updated by the ticker, seeks and pauses.
    private(set) var position: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var gate: PlaybackGate = .noAudio
    /// `TranscriptViewLine.id` of the line at `position`; nil before the first.
    private(set) var currentLine: Int?
    /// No track could be opened at Play.
    private(set) var loadFailed = false
    /// Playback stopped by itself (every sounding track went quiet or a
    /// decode failed); cleared by the next Play or a new session.
    private(set) var stalled = false
    /// The recording the gate last saw (nil = none) and whether its tap
    /// excludes this process.
    private(set) var recordingDir: URL?
    private(set) var excludesSelf = false
    /// Advances when the user starts playback or moves the position (not on
    /// ticks): the transcript resumes following the current line on it.
    private(set) var followEpoch = 0
    /// The user has played or moved the position in this session, so the
    /// current line is worth marking (a fresh session shows none).
    private(set) var hasMoved = false

    private var storedRate = 1.0
    private var volumes: [PlaybackTrackID: Float] = [:]
    private var muted: Set<PlaybackTrackID> = []

    @ObservationIgnored private let makeTrack: @MainActor (PlaybackTrackInfo) -> (any PlaybackTrack)?
    @ObservationIgnored private let ticker: PlaybackTicker
    @ObservationIgnored private let recordingState: @MainActor () -> (dir: URL?, excludesSelf: Bool)
    @ObservationIgnored private var players: [PlaybackTrackID: any PlaybackTrack] = [:]
    /// What `show` was given, to tell a re-read of the same tracks from a change.
    @ObservationIgnored private var sourceTracks: [PlaybackTrackInfo] = []
    @ObservationIgnored private var lines: [TranscriptViewLine] = []
    @ObservationIgnored private var anchorDevice: TimeInterval = 0
    @ObservationIgnored private var anchorT0: TimeInterval = 0
    @ObservationIgnored private var lastResync: TimeInterval = 0

    /// - Parameter recordingState: the running recording's folder and whether
    ///   its tap excludes this process; read at init and on every `show`.
    init(
        makeTrack: @escaping @MainActor (PlaybackTrackInfo) -> (any PlaybackTrack)?,
        ticker: PlaybackTicker,
        recordingState: @escaping @MainActor () -> (dir: URL?, excludesSelf: Bool)
    ) {
        self.makeTrack = makeTrack
        self.ticker = ticker
        self.recordingState = recordingState
        refreshRecordingState()
    }

    /// The real thing: `AVAudioPlayer` tracks and a run-loop timer.
    static func live(recordingState: @escaping @MainActor () -> (dir: URL?, excludesSelf: Bool)) -> PlaybackController {
        PlaybackController(
            makeTrack: { AVPlayerTrack(url: $0.url) },
            ticker: TimerPlaybackTicker(),
            recordingState: recordingState
        )
    }

    var duration: TimeInterval { timeline.duration }
    var canPlay: Bool { gate.canPlay }

    // MARK: - Speed (clamped, R-B.2)

    var rate: Double {
        get { storedRate }
        set {
            let clamped = min(max(newValue, Self.rateRange.lowerBound), Self.rateRange.upperBound)
            guard clamped != storedRate else { return }
            let t = isPlaying ? sessionTime() : position
            storedRate = clamped
            for player in players.values { player.rate = Float(clamped) }
            guard isPlaying else { return }
            position = t
            // Tracks already running follow the new rate on their own; one
            // still waiting was scheduled at the old rate, so start again.
            if timeline.tracks.contains(where: { if case .waiting = timeline.placement(of: $0.id, at: t) { true } else { false } }) {
                startTracks(at: t)
            } else if let clock = clockTrack {
                anchorDevice = clock.deviceCurrentTime
                anchorT0 = t
            }
        }
    }

    // MARK: - Volume and mute

    func volume(for id: PlaybackTrackID) -> Float { volumes[id] ?? 1 }
    func isMuted(_ id: PlaybackTrackID) -> Bool { muted.contains(id) }

    func setVolume(_ value: Float, for id: PlaybackTrackID) {
        volumes[id] = min(max(value, 0), 1)
        applyVolume(id)
    }

    func setMuted(_ isMuted: Bool, for id: PlaybackTrackID) {
        if isMuted { muted.insert(id) } else { muted.remove(id) }
        applyVolume(id)
    }

    private func applyVolume(_ id: PlaybackTrackID) {
        players[id]?.volume = muted.contains(id) ? 0 : volume(for: id)
    }

    // MARK: - Session

    /// Show `dir`. Another folder stops and resets everything; the same folder
    /// again (a rescan) only refreshes the lines and, if the tracks really
    /// changed, stops playback and starts over from the new files.
    func show(dir newDir: URL, tracks: [PlaybackTrackInfo], lines newLines: [TranscriptViewLine]) {
        if let dir, dir.standardizedFileURL.path == newDir.standardizedFileURL.path {
            if tracks != sourceTracks {
                stopAll()
                sourceTracks = tracks
                timeline = PlaybackTimeline(tracks: tracks)
                position = timeline.clamped(position)
                loadFailed = false
            }
        } else {
            resetSession()
            dir = newDir
            sourceTracks = tracks
            timeline = PlaybackTimeline(tracks: tracks)
        }
        lines = newLines
        refreshLine()
        refreshRecordingState()
    }

    /// Nothing is shown any more (no selection, the window closed).
    func unload() {
        resetSession()
        dir = nil
        sourceTracks = []
        timeline = PlaybackTimeline(tracks: [])
        refreshGate()
    }

    /// A recording started or ended (`dir` nil), and whether its tap excludes
    /// this process. Playback that is no longer allowed pauses and does not
    /// resume by itself.
    func recordingChanged(dir: URL?, excludesSelf: Bool) {
        recordingDir = dir
        self.excludesSelf = excludesSelf
        refreshGate()
    }

    private func refreshRecordingState() {
        let state = recordingState()
        recordingChanged(dir: state.dir, excludesSelf: state.excludesSelf)
    }

    private func refreshGate() {
        gate = PlaybackGate.decide(
            session: dir, hasTracks: timeline.isPlayable, recordingDir: recordingDir, excludesSelf: excludesSelf
        )
        if !gate.canPlay, isPlaying { pause() }
    }

    private func resetSession() {
        stopAll()
        position = 0
        currentLine = nil
        hasMoved = false
        storedRate = 1
        volumes = [:]
        muted = []
        loadFailed = false
        stalled = false
        lines = []
    }

    // MARK: - Transport

    func play() {
        guard gate.canPlay, !isPlaying else { return }
        stalled = false
        guard buildPlayers() else { return }
        if timeline.duration > 0, position >= timeline.duration { position = 0 }
        followEpoch += 1
        hasMoved = true
        isPlaying = true
        startTracks(at: position)
        ticker.start(interval: Self.tickInterval) { [weak self] in self?.tick() }
        refreshLine()
    }

    func pause() {
        guard isPlaying else { return }
        position = sessionTime()
        for player in players.values { player.pause() }
        isPlaying = false
        ticker.stop()
        refreshLine()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// Moves to session time `t` (kept inside the session); a playing player
    /// keeps playing from there, a paused one stays paused.
    func seek(to t: TimeInterval) {
        let target = timeline.clamped(t)
        position = target
        followEpoch += 1
        hasMoved = true
        refreshLine()
        if isPlaying { startTracks(at: target) }
    }

    /// A line click: half a second before the line, never before 0.
    func seekToLine(startMs: Int) {
        seek(to: PlaybackTimeline.seekTime(forLineStartMs: startMs))
    }

    // MARK: - Players

    /// Builds the players once; a track that cannot open (or prepare) is left
    /// out of the timeline. Fills a zero length from the player's duration.
    private func buildPlayers() -> Bool {
        if !players.isEmpty { loadFailed = false; return true }
        var kept: [PlaybackTrackInfo] = []
        for info in timeline.tracks {
            guard let player = makeTrack(info) else { continue }
            player.enableRate = true
            guard player.prepareToPlay() else { continue }
            player.rate = Float(storedRate)
            player.onFailure = { [weak self] in self?.stall() }
            players[info.id] = player
            applyVolume(info.id)
            let length = info.length > 0 ? info.length : player.duration
            kept.append(PlaybackTrackInfo(id: info.id, url: info.url, offsetMs: info.offsetMs, length: length))
        }
        guard !kept.isEmpty else {
            loadFailed = true
            return false
        }
        timeline = PlaybackTimeline(tracks: kept)
        loadFailed = false
        return true
    }

    private var clockTrack: (any PlaybackTrack)? {
        PlaybackTrackID.allCases.lazy.compactMap { self.players[$0] }.first
    }

    private func stopAll() {
        for player in players.values { player.stop() }
        players = [:]
        isPlaying = false
        ticker.stop()
    }

    /// Puts every track where `t0` says and schedules them on one device time.
    private func startTracks(at t0: TimeInterval) {
        guard let clock = clockTrack else { return }
        let base = clock.deviceCurrentTime + Self.startLead
        for info in timeline.tracks {
            guard let player = players[info.id] else { continue }
            player.pause()
            player.rate = Float(storedRate)
            switch timeline.placement(of: info.id, at: t0) {
            case .waiting(let delay):
                player.currentTime = 0
                player.play(atTime: base + delay / storedRate)
            case .playing(let local):
                player.currentTime = local
                player.play(atTime: base)
            case .finished, nil:
                break
            }
        }
        anchorDevice = base
        anchorT0 = t0
        lastResync = base
    }

    /// Session time now, from the device clock (never past the session).
    private func sessionTime() -> TimeInterval {
        guard let clock = clockTrack else { return position }
        return timeline.clamped(anchorT0 + max(0, clock.deviceCurrentTime - anchorDevice) * storedRate)
    }

    private func tick() {
        guard isPlaying, let clock = clockTrack else { return }
        let t = sessionTime()
        if t < timeline.duration, hasStalled(at: t, deviceNow: clock.deviceCurrentTime) {
            stall()
            return
        }
        position = t
        refreshLine()
        if t >= timeline.duration {
            finish()
            return
        }
        resyncDrifted(at: t, now: clock.deviceCurrentTime)
    }

    /// Every track that should be sounding at `t` reports it is not playing,
    /// though the tracks were started (the device clock passed the anchor).
    private func hasStalled(at t: TimeInterval, deviceNow: TimeInterval) -> Bool {
        guard deviceNow >= anchorDevice else { return false }
        let sounding = timeline.tracks.compactMap { info -> (any PlaybackTrack)? in
            guard case .playing? = timeline.placement(of: info.id, at: t) else { return nil }
            return players[info.id]
        }
        return !sounding.isEmpty && sounding.allSatisfy { !$0.isPlaying }
    }

    /// Pauses at the last position a tick or pause saw (no clock recompute:
    /// the clock kept running while nothing sounded) and says so.
    private func stall() {
        guard isPlaying else { return }
        for player in players.values { player.pause() }
        isPlaying = false
        stalled = true
        ticker.stop()
        refreshLine()
    }

    private func finish() {
        for player in players.values { player.stop() }
        position = timeline.duration
        isPlaying = false
        ticker.stop()
        refreshLine()
    }

    /// Any track more than `driftThreshold` from where the timeline puts it is
    /// moved there; at most once per `resyncInterval`.
    private func resyncDrifted(at t: TimeInterval, now: TimeInterval) {
        guard now - lastResync >= Self.resyncInterval else { return }
        var resynced = false
        for info in timeline.tracks {
            guard let player = players[info.id], player.isPlaying,
                  case .playing(let expected)? = timeline.placement(of: info.id, at: t),
                  abs(player.currentTime - expected) > Self.driftThreshold
            else { continue }
            player.currentTime = expected
            resynced = true
        }
        if resynced { lastResync = now }
    }

    private func refreshLine() {
        let line = PlaybackTimeline.currentLine(in: lines, at: position)
        if line != currentLine { currentLine = line }
    }
}
