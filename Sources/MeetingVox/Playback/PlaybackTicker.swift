import Foundation

/// The 100 ms heartbeat of the player (position, drift). It runs only while
/// playing, so an idle window costs nothing; a test fires it by hand.
@MainActor
protocol PlaybackTicker: AnyObject {
    var isRunning: Bool { get }
    /// Starts (or restarts) calling `handler` every `interval` seconds.
    func start(interval: TimeInterval, _ handler: @escaping @MainActor () -> Void)
    func stop()
}

/// A `Timer` on the main run loop in `.common` mode, so it keeps ticking while
/// a menu is open or the user scrolls.
@MainActor
final class TimerPlaybackTicker: PlaybackTicker {
    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    func start(interval: TimeInterval, _ handler: @escaping @MainActor () -> Void) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { handler() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
