import Foundation
import UserNotifications

/// What to do with a notice given the app's notification authorization, and
/// how to report a notice that cannot be shown. Pure over the status enum:
/// the center itself is never read here.
enum NotificationAuthorizationPolicy {
    enum Decision: Equatable {
        /// Ask now (the system shows its prompt once), then post if granted.
        case requestThenPost
        case post
        /// Post nothing, and never fall back to another channel.
        case drop
    }

    /// - Parameter requestFailed: an authorization request already threw this
    ///   run; it is not repeated for every notice (the failure is cached).
    static func decide(_ status: UNAuthorizationStatus, requestFailed: Bool = false) -> Decision {
        switch status {
        case .notDetermined: requestFailed ? .drop : .requestThenPost
        case .authorized, .provisional: .post
        default: .drop
        }
    }

    static func name(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    /// How the authorization check ended.
    enum Outcome: Equatable {
        case granted
        /// The user said no (or the system settings say so).
        case denied
        /// The request itself threw; the associated value is the real error.
        case failed(String)
    }

    /// One log line per kind of drop per run, not one per dropped notice.
    struct DropLog {
        private var deniedLogged = false
        private var failedLogged = false

        mutating func line(for outcome: Outcome) -> String? {
            switch outcome {
            case .granted:
                return nil
            case .denied:
                defer { deniedLogged = true }
                return deniedLogged
                    ? nil : "notifications are not allowed for MeetingVox; dropping notices (System Settings → Notifications)"
            case .failed(let error):
                defer { failedLogged = true }
                return failedLogged ? nil : "could not request notification authorization: \(error)"
            }
        }
    }
}
