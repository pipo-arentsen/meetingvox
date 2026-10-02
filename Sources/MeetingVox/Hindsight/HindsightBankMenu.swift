import Foundation

/// The bank choices a "Enviar a memoria"/"Enviar igual" menu offers (the main
/// window's toolbar): the default bank
/// first — checked, titled with `Textos.Memoria.bancoPredeterminado` — then
/// every other known bank (`HindsightBankList.others`) in server order.
/// Always a menu, even with a single (the default) entry: `nil` only when no
/// bank at all is known, so callers fall back to a disabled plain button.
struct HindsightBankMenu: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        /// The label to show, already carrying the " (predeterminado)"
        /// suffix for the default entry.
        let title: String
        /// `nil` selects the default bank (same as the caller's existing
        /// "no bank" convention); non-nil names a specific other bank.
        let bank: String?
        let isDefault: Bool
    }

    let entries: [Entry]

    static func build(defaultBank: String?, otherBanks: [String]) -> HindsightBankMenu? {
        guard defaultBank != nil || !otherBanks.isEmpty else { return nil }
        var entries: [Entry] = []
        if let defaultBank {
            entries.append(Entry(title: Textos.Memoria.bancoPredeterminado(defaultBank), bank: nil, isDefault: true))
        }
        entries.append(contentsOf: otherBanks.map { Entry(title: $0, bank: $0, isDefault: false) })
        return HindsightBankMenu(entries: entries)
    }
}
