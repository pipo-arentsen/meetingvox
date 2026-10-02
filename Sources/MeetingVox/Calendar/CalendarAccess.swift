import Foundation

/// What Settings and onboarding show for the Calendar toggle, and the gate
/// for reading events. Pure: the system status is passed in.
enum CalendarAccess: Sendable, Equatable {
    case off, notDetermined, requesting, authorized, denied, restricted, unavailable

    enum ToggleAction: Sendable, Equatable { case request, none }

    /// `enabled` is `calendar.enabled`. Off hides everything else (the OS
    /// permission is never revoked by the toggle). Write-only access cannot
    /// read events, so it reads as denied. A request in flight shows
    /// `requesting` only while the system has not answered yet.
    static func derive(enabled: Bool, system: CalendarSystemStatus, requesting: Bool) -> CalendarAccess {
        guard enabled else { return .off }
        switch system {
        case .notDetermined: return requesting ? .requesting : .notDetermined
        case .authorized: return .authorized
        case .denied, .writeOnly: return .denied
        case .restricted: return .restricted
        case .unavailable: return .unavailable
        }
    }

    /// Turning the toggle on asks once, and only when the system has never
    /// been asked. Denied/restricted/write-only stay inert (the user changes
    /// them in System Settings); nothing prompts twice.
    static func toggleOn(system: CalendarSystemStatus) -> ToggleAction {
        system == .notDetermined ? .request : .none
    }

    /// Events are read only when the user opted in AND the OS allows it.
    static func effective(enabled: Bool, system: CalendarSystemStatus) -> Bool {
        enabled && system == .authorized
    }
}
