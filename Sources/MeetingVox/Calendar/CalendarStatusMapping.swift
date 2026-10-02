import Foundation

/// The OS-level calendar authorization, in our own terms. `unavailable` =
/// no EventKit in this process (bare binary, tests, doctor, diag).
enum CalendarSystemStatus: Sendable, Equatable {
    case notDetermined, authorized, writeOnly, denied, restricted, unavailable
}

/// Pure halves of the EventKit mapping, keyed by raw value so they are
/// testable without touching EventKit.
enum CalendarStatusMapping {
    /// `EKAuthorizationStatus.rawValue`: 0 notDetermined, 1 restricted,
    /// 2 denied, 3 fullAccess (also the deprecated `.authorized`),
    /// 4 writeOnly. Anything else (a future case) counts as denied: never
    /// grant access we cannot name.
    static func system(rawValue: Int) -> CalendarSystemStatus {
        switch rawValue {
        case 0: .notDetermined
        case 1: .restricted
        case 2: .denied
        case 3: .authorized
        case 4: .writeOnly
        default: .denied
        }
    }

    /// An invitee's address from its EventKit `url` (`mailto:`), else nil.
    static func email(fromParticipantURL url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        let text = url.absoluteString
        let address = String(text.dropFirst("mailto:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? nil : address
    }
}

extension CalendarParticipantStatus {
    /// `EKParticipantStatus.rawValue`: 0 unknown, 1 pending, 2 accepted,
    /// 3 declined, 4 tentative, 5 delegated (completed / in process and any
    /// future value read as unknown).
    init(ekRawValue: Int) {
        switch ekRawValue {
        case 1: self = .pending
        case 2: self = .accepted
        case 3: self = .declined
        case 4: self = .tentative
        case 5: self = .delegated
        default: self = .unknown
        }
    }
}
