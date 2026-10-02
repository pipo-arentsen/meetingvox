import Foundation

/// The single place that writes the "notifications:" stderr prefix.
enum NotificationLog {
    static func formatted(_ message: String) -> String { "notifications: \(message)\n" }

    static func write(_ message: String) {
        FileHandle.standardError.write(Data(formatted(message).utf8))
    }
}
