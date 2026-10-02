import AVFoundation
import Foundation
import UserNotifications

/// The four permissions the onboarding "Permisos" step shows.
enum PermissionKind: CaseIterable, Equatable, Sendable {
    case microphone
    case systemAudio
    case notifications
    case localNetwork
}

/// What AVFoundation and UserNotifications say, folded into one vocabulary so
/// the mapping below does not depend on either framework.
enum SystemAuthorization: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    /// Blocked by a profile or parental control; the user cannot change it.
    case restricted

    init(av status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }

    /// A provisional grant can post, which is all the app needs.
    init(un status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional: self = .authorized
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        @unknown default: self = .denied
        }
    }
}

/// A row's state. `requested` = asked ("Solicitado") but the system gives no
/// definite answer, either because it cannot be read (no TCC SPI) or because
/// it has not been given yet.
enum PermissionStatus: Equatable, Sendable {
    case granted
    case notDetermined
    case denied
    case requested
    case notApplicable
}

/// Which System Settings pane a row's "Abrir Ajustes del Sistema" opens.
enum SettingsPane: Equatable, Sendable {
    case microphone
    case systemAudio
    case notifications
    case localNetwork
}

/// The one button a row offers.
enum RowAction: Equatable, Sendable {
    case none
    /// "Permitir": raises the system prompt (from a single user click).
    case allow
    case openSettings(SettingsPane)
    /// System audio cannot be pre-triggered while a recording runs.
    case waitForRecordingEnd
}

/// A short explanation under a row. Cases, not text: the copy lives in
/// `Textos` with the views.
enum PermissionNote: Equatable, Sendable {
    /// Local Network with the memory integration off: "Cuando actives la memoria".
    case whenMemoryEnabled
    /// Managed by a profile: opening Settings will not help.
    case restrictedByPolicy
    case recordingInProgress
    /// Local Network: the permission is not the problem, the server did not answer.
    case serverUnreachable
    /// Notifications outside the bundled app: there is no center to ask.
    case unavailableOutsideApp
}

struct PermissionRow: Equatable, Sendable {
    var status: PermissionStatus
    var action: RowAction
    var note: PermissionNote?

    init(status: PermissionStatus, action: RowAction, note: PermissionNote? = nil) {
        self.status = status
        self.action = action
        self.note = note
    }
}

// MARK: - Mapping (pure)

extension PermissionStatus {
    /// Microphone or notifications. `requestedThisRun`: the user clicked
    /// "Permitir" in this window. A definite answer wins over it; only a
    /// still-undetermined system after a click reads as "Solicitado".
    static func mapAuthorization(
        _ authorization: SystemAuthorization, pane: SettingsPane, requestedThisRun: Bool
    ) -> PermissionRow {
        switch authorization {
        case .authorized:
            return PermissionRow(status: .granted, action: .none)
        case .notDetermined:
            return requestedThisRun
                ? PermissionRow(status: .requested, action: .openSettings(pane))
                : PermissionRow(status: .notDetermined, action: .allow)
        case .denied:
            return PermissionRow(status: .denied, action: .openSettings(pane))
        case .restricted:
            return PermissionRow(status: .denied, action: .openSettings(pane), note: .restrictedByPolicy)
        }
    }

    /// `nil` = there is no notification center to read (unbundled process).
    static func mapNotifications(_ authorization: SystemAuthorization?, requestedThisRun: Bool) -> PermissionRow {
        guard let authorization else {
            return PermissionRow(status: .notApplicable, action: .none, note: .unavailableOutsideApp)
        }
        return mapAuthorization(authorization, pane: .notifications, requestedThisRun: requestedThisRun)
    }

    /// `tcc` = the preflight of the private TCC call; `nil` when that call is
    /// missing on this macOS. Unreadable or undetermined, the row can only
    /// offer "Permitir" until the user clicked it, then it says "Solicitado".
    /// The prompt is raised by creating a private tap, which a running
    /// recording must not see, hence `waitForRecordingEnd`.
    static func mapSystemAudio(tcc: TCCAccessStatus?, requestedThisRun: Bool, isRecording: Bool) -> PermissionRow {
        switch tcc {
        case .granted:
            return PermissionRow(status: .granted, action: .none)
        case .denied:
            return PermissionRow(status: .denied, action: .openSettings(.systemAudio))
        case .unknown, nil:
            if requestedThisRun {
                return PermissionRow(status: .requested, action: .openSettings(.systemAudio))
            }
            return isRecording
                ? PermissionRow(status: .notDetermined, action: .waitForRecordingEnd, note: .recordingInProgress)
                : PermissionRow(status: .notDetermined, action: .allow)
        }
    }

    /// `probe` is the last result of the click-only Local Network probe, or
    /// `nil` before it ran. `probeRequested`: the user clicked this run.
    static func mapLocalNetwork(
        hindsightEnabled: Bool, probe: LocalNetworkProbe.Result?, probeRequested: Bool
    ) -> PermissionRow {
        guard hindsightEnabled else {
            return PermissionRow(status: .notApplicable, action: .none, note: .whenMemoryEnabled)
        }
        switch probe {
        case .reachable:
            return PermissionRow(status: .granted, action: .none)
        case .prohibited:
            return PermissionRow(status: .denied, action: .openSettings(.localNetwork))
        case .pending:
            // Timed out after the click: the prompt may still be waiting.
            return PermissionRow(status: .requested, action: .allow)
        case .unreachable:
            return PermissionRow(status: .requested, action: .allow, note: .serverUnreachable)
        case nil:
            return probeRequested
                ? PermissionRow(status: .requested, action: .none)
                : PermissionRow(status: .notDetermined, action: .allow)
        }
    }
}
