import Foundation

/// The sidebar's numbers: the total and one count per ámbito,
/// over **all** sessions of the scan — never the current page or filter. Pure.
struct SidebarCounts: Equatable, Sendable {
    let total: Int
    private let byAmbito: [Ambito: Int]
    private let unclassified: Int

    init(_ entries: [MeetingEntry]) {
        total = entries.count
        var counts: [Ambito: Int] = [:]
        var none = 0
        for entry in entries {
            if let ambito = entry.ambito { counts[ambito, default: 0] += 1 } else { none += 1 }
        }
        byAmbito = counts
        unclassified = none
    }

    func count(_ filter: AmbitoFilter) -> Int {
        switch filter {
        case .all: total
        case .only(let ambito): byAmbito[ambito] ?? 0
        case .unclassified: unclassified
        }
    }
}
