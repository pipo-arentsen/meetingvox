import Foundation
import Testing
@testable import MeetingVox

/// How the main window feeds the player (B3): the recording gate through the
/// store's callbacks (the window stays the only subscriber, `jobFinished`
/// keeps running), and the selected session's tracks through the detail data.
@MainActor
@Suite final class MainWindowPlaybackTests {
    let root: URL
    let manual = ManualReloadScheduler()
    let clock = FakeDeviceClock()
    let log = FakeLog()
    let a = URL(fileURLWithPath: "/rec/2026.09.30-1000", isDirectory: true)
    let b = URL(fileURLWithPath: "/rec/2026.09.30-1100", isDirectory: true)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-main-playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["2026.09.30-1000", "2026.09.30-1100"] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"started": "2026-09-30T10:00:00Z", "duration_seconds": 60, "files": {"mic": "mic.caf"}}"#.utf8)
                .write(to: dir.appendingPathComponent(SessionFiles.meta))
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    nonisolated private static func track(_ dir: URL) -> PlaybackTrackInfo {
        PlaybackTrackInfo(id: .mic, url: dir.appendingPathComponent("mic.caf"), offsetMs: 0, length: 60)
    }

    private func makeModel(store: PipelineStatusStore = PipelineStatusStore()) -> MainWindowModel {
        let meetings = MeetingsModel(root: root, config: { ConfigValues(raw: [:]) })
        let session = SessionDetailModel(load: { dir, _, _ in
            SessionDetailData(dir: dir, playbackTracks: [Self.track(dir)])
        })
        let playback = PlaybackController(
            makeTrack: { [clock, log] info in FakePlayerTrack(name: info.id.rawValue, duration: 60, clock: clock, log: log) },
            ticker: ManualTicker(),
            recordingState: { [store] in (store.recordingDir, store.recordingExcludesSelf) }
        )
        return MainWindowModel(
            meetings: meetings, store: store, calendar: .current, now: { Date() },
            reloadScheduler: manual.scheduler, session: session,
            library: (try? TestLibrary.make().library)!, playback: playback
        )
    }

    // MARK: - Gate

    @Test func aRecordingAlreadyRunningSeedsTheGateAtCreationAndOnShow() {
        let store = PipelineStatusStore()
        store.recordingExcludesSelf = false
        store.apply(.recording(b, elapsed: 5))
        let model = makeModel(store: store)
        #expect(model.playback.recordingDir == b)
        model.playback.show(dir: a, tracks: [Self.track(a)], lines: [])
        #expect(model.playback.gate == .pausedWhileRecording)
    }

    @Test func aRecordingStartingFeedsTheGateWithTheStoresExcludesSelf() {
        let store = PipelineStatusStore()
        let model = makeModel(store: store)
        model.playback.show(dir: a, tracks: [Self.track(a)], lines: [])
        #expect(model.playback.gate == .allowed)

        store.recordingExcludesSelf = false
        store.apply(.recording(b, elapsed: 0))
        #expect(model.playback.gate == .pausedWhileRecording)
        #expect(!model.playback.canPlay)

        store.apply(.recording(nil, elapsed: 0))
        #expect(model.playback.gate == .allowed)

        store.recordingExcludesSelf = true
        store.apply(.recording(b, elapsed: 0))
        #expect(model.playback.gate == .pausedWhileRecording, "the speakers would leak into mic.caf even with self-exclusion")
    }

    @Test func stoppingRunsBothTheReloadAndTheGateReEnable() {
        let store = PipelineStatusStore()
        let model = makeModel(store: store)
        model.isActive = true
        model.playback.show(dir: a, tracks: [Self.track(a)], lines: [])
        store.recordingExcludesSelf = false
        store.apply(.recording(b, elapsed: 0))
        #expect(model.playback.gate == .pausedWhileRecording)
        let before = manual.scheduledCount

        store.apply(.recording(nil, elapsed: 0))
        #expect(model.playback.gate == .allowed)
        #expect(manual.scheduledCount == before + 1, "jobFinished still schedules the rescan")
    }

    @Test func playbackPausedByARecordingDoesNotResumeWhenItEnds() {
        let store = PipelineStatusStore()
        let model = makeModel(store: store)
        model.playback.show(dir: a, tracks: [Self.track(a)], lines: [])
        model.playback.play()
        #expect(model.playback.isPlaying)
        store.apply(.recording(b, elapsed: 0))
        #expect(!model.playback.isPlaying)
        store.apply(.recording(nil, elapsed: 0))
        #expect(!model.playback.isPlaying)
    }

    // MARK: - Session data

    @Test func selectingASessionShowsItsTracksAndAnotherSessionReplacesThem() async {
        let model = makeModel()
        await model.reload().value
        let first = model.meetings.entries[0].dir
        let second = model.meetings.entries[1].dir
        await model.session.select(first).value
        #expect(model.playback.dir == first)
        #expect(model.playback.timeline.tracks.map(\.id) == [.mic])
        await model.session.select(second).value
        #expect(model.playback.dir == second)
        await model.session.select(nil).value
        #expect(model.playback.dir == nil)
    }

    @Test func aSessionWithTranscriptLinesHandsThemToThePlayer() async {
        let meetings = MeetingsModel(root: root, config: { ConfigValues(raw: [:]) })
        let lines = [TranscriptViewLine(id: 0, startMs: 0, speaker: "me", text: "hola"), TranscriptViewLine(id: 1, startMs: 4000, speaker: "them", text: "chau")]
        let session = SessionDetailModel(load: { dir, _, _ in
            SessionDetailData(dir: dir, transcriptLines: lines, playbackTracks: [Self.track(dir)])
        })
        let store = PipelineStatusStore()
        let playback = PlaybackController(
            makeTrack: { [clock, log] info in FakePlayerTrack(name: info.id.rawValue, duration: 60, clock: clock, log: log) },
            ticker: ManualTicker(), recordingState: { (nil, false) }
        )
        let model = MainWindowModel(
            meetings: meetings, store: store, calendar: .current, now: { Date() },
            reloadScheduler: manual.scheduler, session: session, library: (try? TestLibrary.make().library)!, playback: playback
        )
        await model.reload().value
        await model.session.select(model.meetings.entries[0].dir).value
        playback.seek(to: 5)
        #expect(playback.currentLine == 1)
    }

    @Test func closingTheWindowUnloadsThePlayer() async {
        let model = makeModel()
        await model.reload().value
        await model.session.select(model.meetings.entries[0].dir).value
        model.isActive = true
        model.playback.play()
        model.isActive = false
        #expect(model.playback.dir == nil)
        #expect(!model.playback.isPlaying)
    }

    @Test func leavingTheTranscriptTabOrThePageStopsTheAudio() async {
        let model = makeModel()
        await model.reload().value
        await model.session.select(model.meetings.entries[0].dir).value
        model.tab = .transcripcion
        model.playback.play()
        #expect(model.playback.isPlaying)
        model.tab = .minuta
        #expect(!model.playback.isPlaying, "no controls are visible on the other tabs")

        model.tab = .transcripcion
        model.playback.play()
        model.sidebar = .tareas
        #expect(!model.playback.isPlaying)
    }
}
