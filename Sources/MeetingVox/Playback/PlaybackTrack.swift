import AVFoundation
import Foundation

/// One track's player, as much of `AVAudioPlayer` as the controller uses, so
/// the controller is tested over a fake and never opens an audio device.
///
/// Two players (mic and system) on one output device share `deviceCurrentTime`,
/// which is what lets both start on the same clock. No `AVAudioEngine` here or
/// anywhere in playback: its input node binds to the default device and
/// destabilizes a Bluetooth headset (see README, Bluetooth notes).
@MainActor
protocol PlaybackTrack: AnyObject {
    /// Length of the file as the player sees it.
    var duration: TimeInterval { get }
    /// The shared output-device clock, in seconds.
    var deviceCurrentTime: TimeInterval { get }
    /// Position inside this track; assigning seeks (also while playing).
    var currentTime: TimeInterval { get set }
    var volume: Float { get set }
    var rate: Float { get set }
    /// Must be set to true **before** `prepareToPlay()` for `rate` to work.
    var enableRate: Bool { get set }
    var isPlaying: Bool { get }
    @discardableResult func prepareToPlay() -> Bool
    /// Starts at `deviceTime` on the device clock (now or later).
    @discardableResult func play(atTime deviceTime: TimeInterval) -> Bool
    func pause()
    /// Halts this run; the position is kept (it is a pause, so the player
    /// stays prepared and reusable for the next Play).
    func stop()
    /// Called when the player fails on its own (decode error), not on a normal end.
    var onFailure: (@MainActor () -> Void)? { get set }
}

/// The real track: an `AVAudioPlayer` over a `.caf`. `AVAudioPlayer(contentsOf:)`
/// only reads the file; nothing in playback writes to a recording.
@MainActor
final class AVPlayerTrack: PlaybackTrack {
    private let player: AVAudioPlayer
    private let failureDelegate: FailureDelegate
    var onFailure: (@MainActor () -> Void)?

    /// nil when the file cannot be opened (missing, damaged, not audio).
    init?(url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        self.player = player
        let delegate = FailureDelegate()
        failureDelegate = delegate
        player.delegate = delegate
        delegate.report = { [weak self] in self?.onFailure?() }
    }

    var duration: TimeInterval { player.duration }
    var deviceCurrentTime: TimeInterval { player.deviceCurrentTime }
    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }
    var enableRate: Bool {
        get { player.enableRate }
        set { player.enableRate = newValue }
    }
    var isPlaying: Bool { player.isPlaying }

    func prepareToPlay() -> Bool { player.prepareToPlay() }
    func play(atTime deviceTime: TimeInterval) -> Bool { player.play(atTime: deviceTime) }
    func pause() { player.pause() }

    /// `AVAudioPlayer.stop()` would tear down the prepared state (and with it
    /// the rate setup); a pause keeps the player reusable for the next Play.
    func stop() { player.pause() }
}

/// `AVAudioPlayer` only talks to an `NSObject` delegate; this forwards its
/// decode error to the main actor.
private final class FailureDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    nonisolated(unsafe) var report: (@MainActor () -> Void)?

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let report = report
        Task { @MainActor in report?() }
    }
}
