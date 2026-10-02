import Foundation

/// One user-visible notification, as a value. Coordinators and the
/// settlement notifier build these (`NoticeBuilder`) and hand them to a
/// `Notifier`; nothing below the backend knows how a notice is shown.
struct Notice: Sendable, Equatable {
    /// The pipeline stage a failure notice is about.
    enum Stage: String, Sendable, Hashable {
        case transcription, minutes, summary, memory
    }

    enum Kind: Sendable, Equatable {
        /// The session settled: everything it was going to get is done.
        /// `memoryAction`: the session could still be sent to memory.
        case ready(memoryAction: Bool)
        /// A minutes request the user made (manual, main window, regenerate)
        /// finished; `file` is the bare name of the file it wrote.
        case minutesReady(file: String)
        /// `retryable`: the stage has a retry path (a definitive Hindsight
        /// rejection of the same content does not).
        case failure(Stage, retryable: Bool)
        case info
    }

    var title: String
    var body: String
    var kind: Kind = .info
    /// The session folder the notice is about, when it is about one.
    var session: URL? = nil

    /// `<kind>-<folder>[-<stage>]`: a repost of the same notice replaces the
    /// earlier one instead of stacking.
    var identifier: String {
        guard let folder = session?.lastPathComponent else { return "info-\(title)" }
        switch kind {
        case .ready: return "ready-\(folder)"
        case .minutesReady: return "minutes-\(folder)"
        case .failure(let stage, _): return "failure-\(folder)-\(stage.rawValue)"
        case .info: return "info-\(folder)"
        }
    }
}
