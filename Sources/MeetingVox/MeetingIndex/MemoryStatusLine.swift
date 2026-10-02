import Foundation

/// The sentence the detail keeps for the memory state: what the old Reuniones row
/// said beside its button ("En memoria (banco) — fecha", "Error al enviar"…),
/// which the stepper's dot cannot. nil when there is nothing to say. Pure.
enum MemoryStatusLine {
    static func text(_ status: HindsightStatus?, timeZone: TimeZone) -> String? {
        switch status {
        case .sent(let date, let bank): Textos.Memoria.enMemoria(sentAt(date, timeZone), banco: bank)
        case .error: Textos.Memoria.errorEnvio
        case .omitted: Textos.Memoria.noSeEnvia
        case .pending: Textos.Memoria.pendienteEnvio
        case .short: Textos.Memoria.muyCorta
        case .notSent, nil: nil
        }
    }

    /// `24 sep 2026, 18:05` with the fixed Spanish month abbreviations, so it
    /// reads the same on every machine.
    private static func sentAt(_ date: Date, _ timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let month = Textos.Indice.mesesCortos[(parts.month ?? 1) - 1]
        return "\(parts.day ?? 1) \(month) \(parts.year ?? 0), \(MeetingRowHeader.clock(date, calendar))"
    }
}
