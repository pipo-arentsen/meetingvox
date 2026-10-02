import Foundation

/// What the one persistent pill window shows. Pure: the controller feeds it
/// events and renders `face`; nothing here knows about AppKit, audio or config.
///
/// Two independent pieces of state share the window: a *prompt* (a detected
/// meeting or an ended one, always shown, whatever the setting says) and the
/// *recording* face (shown only while `pillEnabled` and not hidden by the user).
struct PillState: Equatable, Sendable {
    enum Prompt: Equatable, Sendable {
        case detected(label: String)
        case ended(title: String)
    }

    struct Recording: Equatable, Sendable {
        /// The user hid this recording's pill; cleared by the next recording,
        /// by re-enabling the setting, or by a silent mic.
        var hidden = false
        var micSilent = false
    }

    /// The face the window draws; `.hidden` = the window is ordered out.
    enum Face: Equatable, Sendable {
        case hidden
        case detected(String)
        case recording
        case silentMic
        case ended(String)
    }

    enum Event: Equatable, Sendable {
        case promptDetected(label: String)
        case promptEnded(title: String)
        /// The prompt closed (Ignorar, Grabar, Seguir grabando, withdrawn, timeout).
        case promptClosed
        case recordingStarted(pillEnabled: Bool)
        case recordingStopped
        case hideTapped
        case micSilent
        case micBack
        case settingChanged(Bool)
    }

    private(set) var prompt: Prompt?
    private(set) var recording: Recording?
    private(set) var pillEnabled: Bool

    init(pillEnabled: Bool = true) { self.pillEnabled = pillEnabled }

    private var recordingFaceShows: Bool {
        guard let recording else { return false }
        return pillEnabled && !recording.hidden
    }

    var face: Face {
        if case .ended(let title)? = prompt { return .ended(title) }
        if recordingFaceShows { return recording?.micSilent == true ? .silentMic : .recording }
        if case .detected(let label)? = prompt { return .detected(label) }
        return .hidden
    }

    /// The window is on screen.
    var isVisible: Bool { prompt != nil || recordingFaceShows }

    /// A *prompt* is up. Deliberately not `isVisible`: a recording pill on
    /// screen must not make the detectors hold their prompts (the end machine
    /// would never emit during a recording).
    var isPromptVisible: Bool { prompt != nil }

    mutating func reduce(_ event: Event) {
        switch event {
        case .promptDetected(let label):
            // Only while idle and with nothing else up: a recording never
            // starts a detection prompt and one prompt shows at a time.
            if recording == nil, prompt == nil { prompt = .detected(label: label) }
        case .promptEnded(let title):
            prompt = .ended(title: title)
        case .promptClosed:
            prompt = nil
        case .recordingStarted(let enabled):
            pillEnabled = enabled
            recording = Recording()
            if case .detected? = prompt { prompt = nil }
        case .recordingStopped:
            recording = nil
            if case .ended? = prompt { prompt = nil }
        case .hideTapped:
            recording?.hidden = true
        case .micSilent:
            guard recording != nil else { return }
            recording?.micSilent = true
            if pillEnabled { recording?.hidden = false }
        case .micBack:
            recording?.micSilent = false
        case .settingChanged(let enabled):
            pillEnabled = enabled
            if enabled { recording?.hidden = false }
        }
    }
}
