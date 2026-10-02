import Foundation

/// `asistentes` for Hindsight's metadata, read from the local `minuta.md`
/// (the minutes themselves never leave the Mac). Heuristic by design: it
/// follows the section names of the factory templates.
enum HindsightAttendees {
    /// First `##` section with one of these titles (case-insensitive).
    static let sectionTitles: Set<String> = ["asistentes", "participantes", "participante"]
    /// The daily template's fixed `##` sections; every other `##` heading
    /// of a daily is a person.
    static let dailySections: Set<String> = [
        "oportunidades mencionadas", "bloqueos que requieren seguimiento", "acuerdos", "otros temas",
    ]
    /// Bullet labels the templates put before the names ("Yo: <nombre>").
    static let labels: Set<String> = ["yo", "otros", "por nuestro equipo", "por el cliente", "socios u otros"]
    /// Entries that are not people (compared folded, trailing "." removed).
    static let discarded: Set<String> = ["participantes no identificados", "no se menciono", "...", "yo", "otros"]

    static func parse(minutes: String, templateID: String?) -> [String] {
        let lines = minutes.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let raw: [String]
        if let bullets = sectionBullets(lines) {
            raw = bullets.flatMap(entries)
        } else if templateID == "daily" {
            raw = lines.compactMap(heading).filter { !dailySections.contains($0.lowercased()) }
        } else {
            raw = []
        }
        var seen: Set<String> = []
        return raw.compactMap(clean).filter { seen.insert(fold($0)).inserted }
    }

    /// `## Title` → "Title"; nil for any other line (including `###`).
    private static func heading(_ line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// Bullet texts (any indentation) of the first attendees section, which
    /// ends at the next level-1 or level-2 heading. Nil when there is none.
    private static func sectionBullets(_ lines: [String]) -> [String]? {
        guard let start = lines.firstIndex(where: { heading($0).map { sectionTitles.contains($0.lowercased()) } ?? false })
        else { return nil }
        var bullets: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("# ") || line.hasPrefix("## ") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
                bullets.append(String(trimmed.dropFirst(marker.count)))
            }
        }
        return bullets
    }

    /// One bullet → comma-separated names, without bold markup or a
    /// template label before the first colon.
    private static func entries(_ bullet: String) -> [String] {
        var text = bullet.replacingOccurrences(of: "**", with: "")
        if let colon = text.firstIndex(of: ":"),
           labels.contains(text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()) {
            text = String(text[text.index(after: colon)...])
        }
        return text.components(separatedBy: ",")
    }

    /// Drops "(?)" and blanks; nil for non-people entries.
    private static func clean(_ entry: String) -> String? {
        let name = entry.replacingOccurrences(of: "(?)", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var key = fold(name)
        while key.hasSuffix("."), key != "..." { key.removeLast() }
        return discarded.contains(key) ? nil : name
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
