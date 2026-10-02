import Foundation

/// First line of the detail header: `Jue 24 sep · 10:53–11:05
/// (12 min)` in local time. The end is meta.json `ended` (when not before the
/// start), else start + `duration_seconds`; with neither, only the start. A
/// meeting past midnight keeps the start's day. Pure.
enum MeetingRowHeader {
    static func text(started: Date?, ended: Date?, durationSeconds: Int?, timeZone: TimeZone) -> String? {
        guard let started else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .day, .month], from: started)
        guard let weekday = parts.weekday, let day = parts.day, let month = parts.month else { return nil }
        let date = "\(Textos.Indice.diasCortos[weekday - 1]) \(day) \(Textos.Indice.mesesCortos[month - 1])"
        let start = clock(started, calendar)

        guard let end = end(started: started, ended: ended, durationSeconds: durationSeconds) else {
            return "\(date) · \(start)"
        }
        let minutes = Int((end.timeIntervalSince(started) / 60).rounded())
        return "\(date) · \(start)–\(clock(end, calendar)) (\(Textos.Indice.duracion(minutos: minutes)))"
    }

    /// `ended` when it is not before the start, else start + the recorded
    /// duration; nil with neither.
    static func end(started: Date, ended: Date?, durationSeconds: Int?) -> Date? {
        if let ended, ended >= started { return ended }
        if let durationSeconds, durationSeconds >= 0 { return started.addingTimeInterval(TimeInterval(durationSeconds)) }
        return nil
    }

    static func clock(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
