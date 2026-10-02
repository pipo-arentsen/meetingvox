import SwiftUI

/// A player with no audio behind it, for the headless snapshots: it only
/// remembers what it was told, so drawing the player never opens a file or an
/// output device.
@MainActor
final class SnapshotTrack: PlaybackTrack {
    let duration: TimeInterval
    let deviceCurrentTime: TimeInterval = 1_000
    var onFailure: (@MainActor () -> Void)?
    var currentTime: TimeInterval = 0
    var volume: Float = 1
    var rate: Float = 1
    var enableRate = false
    private(set) var isPlaying = false

    init(duration: TimeInterval) { self.duration = duration }

    func prepareToPlay() -> Bool { true }
    func play(atTime deviceTime: TimeInterval) -> Bool {
        isPlaying = true
        return true
    }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}

/// A ticker that never ticks: the snapshot freezes the player where it was put.
@MainActor
final class SnapshotTicker: PlaybackTicker {
    private(set) var isRunning = false
    func start(interval: TimeInterval, _ handler: @escaping @MainActor () -> Void) { isRunning = true }
    func stop() { isRunning = false }
}

/// The player states of the Transcripción tab: two tracks paused
/// and playing (current line marked), one track, and the bar disabled while
/// another session is being recorded. Fake tracks, the fixture root only.
enum SnapshotPlaybackStates {
    static let windowSize = MainLayout.defaultSize

    @MainActor
    static var all: [SnapshotState] { [player, playerPlaying, playerOneTrack, playerDisabledRecording] }

    /// The "complete" fixture is 47 minutes; its files do not exist, so the
    /// tracks are made up: mic at 0, system 120 ms later, like meta.json.
    private static let length: TimeInterval = 47 * 60

    private static var twoTracks: [PlaybackTrackInfo] {
        [
            PlaybackTrackInfo(id: .mic, url: URL(fileURLWithPath: "/snapshot/mic.caf"), offsetMs: 0, length: length),
            PlaybackTrackInfo(id: .system, url: URL(fileURLWithPath: "/snapshot/system.caf"), offsetMs: 120, length: length - 0.12),
        ]
    }

    @MainActor
    private static func view(
        _ context: SnapshotContext, tracks: [PlaybackTrackInfo], playing: Bool = false, recording: Bool = false
    ) -> AnyView {
        let store = PipelineStatusStore()
        if recording, let recorded = context.installed.dirs(of: .inProgress).first {
            store.recordingExcludesSelf = false
            store.apply(.recording(recorded, elapsed: 754))
        }
        let playback = PlaybackController(
            makeTrack: { SnapshotTrack(duration: $0.length) }, ticker: SnapshotTicker(),
            recordingState: { [store] in (store.recordingDir, store.recordingExcludesSelf) }
        )
        let model = context.env.makeMainWindowModel(store: store, playback: playback, playbackTracks: tracks)
        SnapshotEnvironment.load(model)
        model.tab = .transcripcion
        if let fixture = context.installed.dirs(of: .complete).first,
           let entry = model.meetings.entries.first(where: { $0.dir.standardizedFileURL == fixture.standardizedFileURL }) {
            model.meetings.selection = [entry.dir]
            SnapshotEnvironment.loadDetail(model)
        }
        // Ten seconds into the third line, so it is the current one.
        if !recording, let lines = model.session.data?.transcriptLines, lines.count > 2 {
            playback.seek(to: Double(lines[2].startMs) / 1000 + 10)
            if playing { playback.play() }
        }
        return AnyView(MainView(model: model, onToggleRecording: {}, flatColumns: true))
    }

    @MainActor
    static let player = SnapshotState(name: "tab-transcripcion-player", width: windowSize.width, height: windowSize.height) {
        view($0, tracks: twoTracks)
    }

    @MainActor
    static let playerPlaying = SnapshotState(name: "tab-transcripcion-player-playing", width: windowSize.width, height: windowSize.height) {
        view($0, tracks: twoTracks, playing: true)
    }

    /// Only `mic.caf`: the Otros controls are not drawn.
    @MainActor
    static let playerOneTrack = SnapshotState(name: "tab-transcripcion-player-one-track", width: windowSize.width, height: windowSize.height) {
        view($0, tracks: [twoTracks[0]])
    }

    /// Another session is being recorded and the tap does not exclude this
    /// process: the controls are dimmed and the bar says playback is paused.
    @MainActor
    static let playerDisabledRecording = SnapshotState(
        name: "tab-transcripcion-player-disabled-recording", width: windowSize.width, height: windowSize.height
    ) {
        view($0, tracks: twoTracks, recording: true)
    }
}
