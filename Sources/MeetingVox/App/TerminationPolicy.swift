import Foundation

/// What to do when something asks the app to quit: ⌘Q, the menu's Quit,
/// SIGTERM, SIGINT, logout, `launchctl bootout`. They all end in
/// `NSApp.terminate`, which asks `applicationShouldTerminate`, which asks this.
enum TerminationPolicy {
    enum Decision: Equatable {
        /// Nothing to finalize: terminate immediately.
        case now
        /// Stop the live recording synchronously (meta.json is written), then
        /// reply to AppKit after `drain`, so the asynchronous capture and tap
        /// teardown finishes first.
        case stopThenLater(drain: TimeInterval)
        /// A termination is already waiting for its reply; the pending one is
        /// the one that counts. Don't stop or schedule anything again.
        case alreadyInProgress
    }

    /// Well under launchd's 20 s `ExitTimeOut`. Anything the drain cuts short
    /// is recoverable: the transcription queue resumes from the filesystem at
    /// the next launch.
    static let drain: TimeInterval = 1.0

    static func decide(isRecording: Bool, alreadyTerminating: Bool) -> Decision {
        if alreadyTerminating { return .alreadyInProgress }
        return isRecording ? .stopThenLater(drain: drain) : .now
    }
}
