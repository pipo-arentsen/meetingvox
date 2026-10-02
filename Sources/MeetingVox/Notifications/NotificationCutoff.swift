import Foundation

/// The instant this notification scheme first ran on this Mac. A session that
/// started before it never gets a "reunión lista" notice — not at launch, not
/// when a resumed pipeline finishes it later, not after "Reconstruir índice" —
/// so upgrading does not announce months of old meetings.
///
/// Stored as ISO 8601 in `notificaciones.desde`. A missing or malformed file
/// means "now" and is rewritten. If it cannot be written the cutoff is still
/// "now" for this process (logged), and the next launch tries again.
enum NotificationCutoff {
    static func load(
        at file: URL, now: Date,
        write: (_ text: String, _ file: URL) throws -> Void = defaultWrite,
        log: (_ message: String) -> Void = { NotificationLog.write($0) }
    ) -> Date {
        if let text = try? String(contentsOf: file, encoding: .utf8), let date = parse(text) { return date }
        do {
            try write(format(now) + "\n", file)
        } catch {
            log("could not write \(file.lastPathComponent): \(error)")
        }
        return now
    }

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: trimmed) ?? fractional.date(from: trimmed)
    }

    static func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func defaultWrite(_ text: String, _ file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: file, options: .atomic)
    }
}
