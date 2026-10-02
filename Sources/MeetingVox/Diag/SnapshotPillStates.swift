import SwiftUI

/// The recording pill's five faces, drawn from a `PillViewModel` filled with
/// fixed values. Nothing here
/// reads config, Keychain or the real home: the pill view takes only its
/// model, and the templates are two literals. The pill's own panel is never
/// created; the view sits on a plain backdrop of the panel's width.
enum SnapshotPillStates {
    @MainActor
    static var all: [SnapshotState] { [detected, recording, silentMic, ended, endedCountdown] }

    private static let templates = [
        MinutesTemplate(id: "general", nombre: "General", descripcion: "", cuerpo: ""),
        MinutesTemplate(id: "comercial", nombre: "Comercial", descripcion: "", cuerpo: ""),
    ]

    @MainActor
    private static func state(_ name: String, _ configure: @escaping @MainActor (PillViewModel) -> Void) -> SnapshotState {
        SnapshotState(name: name, width: RecordingPillPanel.width + 40, height: nil) { _ in
            let model = PillViewModel()
            configure(model)
            return AnyView(
                RecordingPillView(model: model)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(20)
                    .background(Color(white: 0.55))
            )
        }
    }

    /// A meeting was detected: template picker, Ignorar / Grabar.
    @MainActor
    static let detected = state("pill-detected") {
        $0.face = .detected("Teams")
        $0.templates = templates
        $0.selection = "general"
    }

    /// Recording: Yo at a low-mid level, Otros at a high one.
    @MainActor
    static let recording = state("pill-recording") {
        $0.face = .recording
        $0.elapsed = "12:34"
        $0.mic = .level(0.38)
        $0.system = .level(0.72)
        $0.templates = templates
        $0.selection = "comercial"
    }

    /// The mic stopped delivering audio (hard mute); Otros has no signal ("—").
    @MainActor
    static let silentMic = state("pill-silent-mic") {
        $0.face = .silentMic
        $0.elapsed = "3:05"
        $0.mic = .level(0)
        $0.system = .unavailable
    }

    /// The meeting ended; the user must answer.
    @MainActor
    static let ended = state("pill-ended") {
        $0.face = .ended("La reunión de Teams terminó")
        $0.elapsed = "41:20"
    }

    /// Same, with auto-stop on: "Se detiene sola en 0:32".
    @MainActor
    static let endedCountdown = state("pill-ended-countdown") {
        $0.face = .ended("La reunión de Teams terminó")
        $0.elapsed = "41:20"
        $0.countdown = "0:32"
    }
}
