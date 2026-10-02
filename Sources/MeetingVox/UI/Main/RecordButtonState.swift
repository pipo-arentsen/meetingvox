import Foundation

/// "0:00", "12:34", "1:02:05": the recording clock as the title strip and the
/// menu bar show it. Pure.
enum ElapsedText {
    static func format(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// What the title strip's red button says and does (MW: "● Grabar ⌘R" /
/// "■ Detener 12:34"). Pure; derived from the store's recording.
enum RecordButtonState: Equatable {
    case start
    case stop(elapsed: String)

    static func of(_ recording: PipelineState.Recording?) -> RecordButtonState {
        guard let recording else { return .start }
        return .stop(elapsed: ElapsedText.format(recording.elapsed))
    }

    var isRecording: Bool { self != .start }

    var title: String {
        switch self {
        case .start: Textos.Principal.grabar
        case .stop(let elapsed): Textos.Principal.detener(elapsed)
        }
    }
}
