@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import MeetingVox

/// A mic that is metered, reports signal changes and can drop out.
private final class MeteredMic: MicRecording, MeteredTrack, MicSignalReporting, @unchecked Sendable {
    struct Failure: Error {}

    let level = LevelTap()
    var diagBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onUnavailable: (@Sendable (Error) -> Void)?
    var onSignalChange: (@Sendable (MicSignal) -> Void)?
    private(set) var isRecording = false
    let firstBufferAt: Date? = nil
    let throwsOnStart: Bool
    /// What `onSignalChange` was when `start` ran: the session must set it before.
    private(set) var signalCallbackSetAtStart = false

    init(throwsOnStart: Bool = false) { self.throwsOnStart = throwsOnStart }

    func start(writingTo url: URL) throws {
        signalCallbackSetAtStart = onSignalChange != nil
        if throwsOnStart { throw Failure() }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        isRecording = true
    }

    func stop() { isRecording = false }
}

/// A mic that is neither metered nor a signal reporter (the VPIO engine).
private final class PlainMic: MicRecording, @unchecked Sendable {
    var diagBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onUnavailable: (@Sendable (Error) -> Void)?
    private(set) var isRecording = false
    let firstBufferAt: Date? = nil

    func start(writingTo url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        isRecording = true
    }

    func stop() { isRecording = false }
}

private final class MeteredSystem: TrackRecording, MeteredTrack, @unchecked Sendable {
    struct Failure: Error {}

    let level = LevelTap()
    private(set) var isRecording = false
    let firstBufferAt: Date? = nil
    let throwsOnStart: Bool

    init(throwsOnStart: Bool = false) { self.throwsOnStart = throwsOnStart }

    func start(writingTo url: URL) throws {
        if throwsOnStart { throw Failure() }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        isRecording = true
    }

    func stop() { isRecording = false }
}

private final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MicSignal] = []
    var all: [MicSignal] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ signal: MicSignal) { lock.lock(); items.append(signal); lock.unlock() }
}

@Suite struct RecordingSessionLevelsTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingvox-levels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func session(mic: MicRecording, system: TrackRecording) throws -> RecordingSession {
        try RecordingSession(root: try tempRoot(), mic: mic, system: system, notify: { _, _ in })
    }

    @Test func meteredTracksReportTheirPeaks() throws {
        let mic = MeteredMic(), system = MeteredSystem()
        let session = try session(mic: mic, system: system)
        try session.start()
        mic.level.publish(0.5)
        system.level.publish(0.25)
        #expect(session.levels() == LevelSnapshot(mic: .sample(0.5), system: .sample(0.25)))
        // Swap-to-zero: nothing written since.
        #expect(session.levels() == LevelSnapshot(mic: .sample(nil), system: .sample(nil)))
    }

    @Test func aNonMeteredMicIsUnavailable() throws {
        let system = MeteredSystem()
        let session = try session(mic: PlainMic(), system: system)
        try session.start()
        system.level.publish(0.1)
        #expect(session.levels() == LevelSnapshot(mic: .unavailable, system: .sample(0.1)))
    }

    @Test func aTrackThatFailedToStartIsUnavailable() throws {
        let mic = MeteredMic(throwsOnStart: true), system = MeteredSystem()
        let session = try session(mic: mic, system: system)
        try session.start()
        #expect(session.levels().mic == .unavailable)
        #expect(session.levels().system == .sample(nil))

        let session2 = try self.session(mic: MeteredMic(), system: MeteredSystem(throwsOnStart: true))
        try session2.start()
        #expect(session2.levels().system == .unavailable)
    }

    @Test func nothingIsStartedBeforeStartOrAfterStop() throws {
        let mic = MeteredMic(), system = MeteredSystem()
        let session = try session(mic: mic, system: system)
        #expect(session.levels() == LevelSnapshot(mic: .unavailable, system: .unavailable))
        try session.start()
        session.stop()
        #expect(session.levels() == LevelSnapshot(mic: .unavailable, system: .unavailable))
    }

    @Test func aMicLostAfterStartIsUnavailable() throws {
        let mic = MeteredMic()
        let session = try session(mic: mic, system: MeteredSystem())
        try session.start()
        mic.onUnavailable?(MeteredMic.Failure())
        #expect(session.levels().mic == .unavailable)
    }

    @Test func onMicSignalIsForwardedToTheMicBeforeStart() throws {
        let mic = MeteredMic()
        let session = try session(mic: mic, system: MeteredSystem())
        let signals = Signals()
        session.onMicSignal = { signals.add($0) }
        try session.start()
        #expect(mic.signalCallbackSetAtStart)
        mic.onSignalChange?(.silent)
        mic.onSignalChange?(.back)
        #expect(signals.all == [.silent, .back])
    }

    @Test func aMicThatDoesNotReportSignalsIgnoresOnMicSignal() throws {
        let session = try session(mic: PlainMic(), system: MeteredSystem())
        session.onMicSignal = { _ in }
        try session.start()
        #expect(session.levels().mic == .unavailable)
    }
}

/// The recorders' own seams (no Core Audio, no capture session is started).
@Suite struct RecorderMeteringTests {
    @Test func theCaptureMicIsMeteredAndReportsSignals() {
        let mic = CaptureMicRecorder()
        let metered: MeteredTrack = mic
        #expect(metered.level.sample() == nil)
        let reporter: MicSignalReporting = mic
        #expect(reporter.onSignalChange == nil)
    }

    @Test func theSystemTapIsMetered() {
        let tap = SystemAudioRecorder(ownProcessObject: { nil }, attempt: { _, _ in }, log: { _ in })
        let metered: MeteredTrack = tap
        #expect(metered.level.sample() == nil)
    }

    @Test func deadMicEventsMapToSignals() {
        #expect(MicSignal(.dead(silentFor: 11)) == .silent)
        #expect(MicSignal(.recovered) == .back)
    }

    @Test func theDetectorYieldsOneSignalPerTransition() {
        var detector = DeadMicDetector()
        var signals: [MicSignal] = []
        var time: TimeInterval = 0
        // Silence for 30 s, then sound for 5 s, then silence again.
        for peak: Float in [Float](repeating: 0, count: 30) + [Float](repeating: 0.5, count: 5)
            + [Float](repeating: 0, count: 20) {
            time += 1
            if let event = detector.observe(peak: peak, at: time) { signals.append(MicSignal(event)) }
        }
        #expect(signals == [.silent, .back, .silent])
    }
}
