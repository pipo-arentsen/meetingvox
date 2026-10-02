import Foundation
import Observation

/// What the pill's SwiftUI faces draw and the buttons they call. A display
/// model only: `RecordingPillController` writes it, the views read it. No
/// config, Keychain or home access, so the headless snapshots can build one
/// directly.
@MainActor
@Observable
final class PillViewModel {
    var face: PillState.Face = .hidden
    /// `m:ss` since the recording started.
    var elapsed = "0:00"
    var mic: MeterReading.Display = .level(0)
    var system: MeterReading.Display = .level(0)
    /// nil hides the picker (minutes disabled).
    var templates: [MinutesTemplate]?
    var selection: String?
    /// `m:ss` left until the end prompt stops the recording by itself; nil =
    /// no countdown, and the "se detiene sola" line is not drawn.
    var countdown: String?

    @ObservationIgnored var onRecord: (String?) -> Void = { _ in }
    @ObservationIgnored var onIgnore: () -> Void = {}
    @ObservationIgnored var onStop: () -> Void = {}
    @ObservationIgnored var onContinue: () -> Void = {}
    @ObservationIgnored var onHide: () -> Void = {}
    @ObservationIgnored var onChangeMic: () -> Void = {}
    /// Set only while recording: the picker of the detected prompt just
    /// remembers the choice until "Grabar".
    @ObservationIgnored var onTemplateChanged: ((String) -> Void)?

    /// The picker's choice from the UI (the owner is told while recording).
    func select(_ id: String?) {
        selection = id
        if let id { onTemplateChanged?(id) }
    }
}
