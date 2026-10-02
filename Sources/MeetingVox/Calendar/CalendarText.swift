import Foundation

/// Calendar text is written by other people (an invitation can say anything),
/// so it is cleaned once, where a `CalendarEventRecord` is built: every
/// whitespace run, newlines included, becomes one space, and the length is
/// capped. meta.json, the prompts, Hindsight and `indice.md` then all get the
/// same single line.
enum CalendarText {
    static let titleLimit = 200
    static let nameLimit = 80

    static func clean(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(limit))
    }

    static func title(_ text: String) -> String { clean(text, limit: titleLimit) }

    static func name(_ text: String) -> String { clean(text, limit: nameLimit) }
}
