import Foundation

@testable import MeetingVox

/// The one device clock every fake track shares, like two `AVAudioPlayer`s on
/// one output device.
@MainActor
final class FakeDeviceClock {
    var now: TimeInterval = 100
}

/// Everything the fakes did, in order, so a test can assert on sequence.
@MainActor
final class FakeLog {
    var events: [String] = []
}

/// An `AVAudioPlayer` stand-in that follows the shared clock: once playing and
/// started, `currentTime` advances with it at `rate`; `drift` is added on top
/// so a test can push a track off the timeline.
@MainActor
final class FakePlayerTrack: PlaybackTrack {
    let name: String
    let clock: FakeDeviceClock
    let log: FakeLog
    var duration: TimeInterval
    var volume: Float = 1 { didSet { log.events.append("\(name).volume=\(volume)") } }
    var rate: Float = 1 { didSet { log.events.append("\(name).rate=\(rate)") } }
    var enableRate = false { didSet { log.events.append("\(name).enableRate=\(enableRate)") } }
    private(set) var isPlaying = false
    private(set) var scheduledStart: TimeInterval?
    private(set) var setPositions: [TimeInterval] = []
    var drift: TimeInterval = 0
    var prepareResult = true
    var onFailure: (@MainActor () -> Void)?

    private var anchorPosition: TimeInterval = 0
    private var startedAt: TimeInterval = 0

    init(name: String, duration: TimeInterval, clock: FakeDeviceClock, log: FakeLog) {
        self.name = name
        self.duration = duration
        self.clock = clock
        self.log = log
    }

    var deviceCurrentTime: TimeInterval { clock.now }

    var currentTime: TimeInterval {
        get {
            guard isPlaying, clock.now >= startedAt else { return anchorPosition }
            return anchorPosition + (clock.now - startedAt) * Double(rate) + drift
        }
        set {
            setPositions.append(newValue)
            log.events.append("\(name).currentTime=\(String(format: "%.3f", newValue))")
            anchorPosition = newValue
            startedAt = clock.now
            drift = 0
        }
    }

    func prepareToPlay() -> Bool {
        log.events.append("\(name).prepare(enableRate: \(enableRate))")
        return prepareResult
    }

    func play(atTime deviceTime: TimeInterval) -> Bool {
        log.events.append("\(name).play(at: \(String(format: "%.3f", deviceTime - clock.now)) from now)")
        scheduledStart = deviceTime
        startedAt = deviceTime
        isPlaying = true
        return true
    }

    func pause() {
        anchorPosition = currentTime
        isPlaying = false
        log.events.append("\(name).pause")
    }

    func stop() {
        isPlaying = false
        log.events.append("\(name).stop")
    }

    /// The real player went quiet on its own (route change, device gone).
    func simulateStall() { isPlaying = false }

    /// The real player hit a decode error mid-play.
    func simulateDecodeError() {
        isPlaying = false
        onFailure?()
    }
}

/// A ticker a test fires by hand; `isRunning` says whether it is armed.
@MainActor
final class ManualTicker: PlaybackTicker {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private var handler: (@MainActor () -> Void)?

    func start(interval: TimeInterval, _ handler: @escaping @MainActor () -> Void) {
        isRunning = true
        startCount += 1
        self.handler = handler
    }

    func stop() {
        isRunning = false
        handler = nil
    }

    func fire() { handler?() }
}
