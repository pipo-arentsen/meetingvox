import Foundation

/// The player bar's pure copy and visibility rules, apart from the view so
/// they are unit-tested.
enum PlayerBarText {
    /// The speeds the menu offers (all inside `PlaybackController.rateRange`).
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// "0,75×": a Spanish decimal comma, no trailing zeros.
    static func speed(_ rate: Double) -> String {
        let text = String(format: "%g", rate).replacingOccurrences(of: ".", with: ",")
        return "\(text)×"
    }

    /// `mm:ss` (`h:mm:ss` past the hour), the same stamps as the transcript lines.
    static func clock(_ seconds: TimeInterval) -> String {
        PromptBuilder.timestamp(Int((max(0, seconds) * 1000).rounded(.down)))
    }

    /// What a disabled bar says; nil when playback is allowed.
    static func message(for gate: PlaybackGate) -> String? {
        switch gate {
        case .allowed: nil
        case .pausedWhileRecording: Textos.Reproductor.pausadoGrabando
        case .thisSessionRecording: Textos.Reproductor.estaSesionGrabando
        case .noAudio: Textos.Reproductor.sinAudio
        }
    }

    /// The bar's one status line: the gate's reason first, then a failed open,
    /// then a playback that stopped by itself; nil when there is nothing to say.
    static func message(for gate: PlaybackGate, loadFailed: Bool, stalled: Bool) -> String? {
        if let reason = message(for: gate) { return reason }
        if loadFailed { return Textos.Reproductor.noSeAbrio }
        return stalled ? Textos.Reproductor.seDetuvo : nil
    }

    /// A session with no audio at all shows no bar; every other case shows it
    /// (disabled, with its reason, when playback is not allowed).
    static func showsBar(for gate: PlaybackGate) -> Bool { gate != .noAudio }
}
