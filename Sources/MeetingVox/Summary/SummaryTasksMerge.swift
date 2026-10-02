import Foundation

/// Merge-only write of a tasks backfill into an existing `resumen.json`.
/// Works on the raw JSON object (not on `MeetingSummary`), so every other
/// key — including ones this version does not know — survives value-equal;
/// only key order and whitespace may change. Pure: `Data → Data`.
enum SummaryTasksMerge {
    enum MergeError: Error, Equatable, CustomStringConvertible {
        /// The file is not a JSON object.
        case notAnObject
        /// A `tasks` key already exists (even a malformed one): the session
        /// was extracted already, so the merge refuses instead of overwriting.
        case alreadyHasTasks

        var description: String {
            switch self {
            case .notAnObject: "resumen.json is not a JSON object"
            case .alreadyHasTasks: "resumen.json already has a tasks key"
            }
        }
    }

    /// Adds `tasks` (and `country`, when there is one and the file has none;
    /// an existing non-blank country is never overwritten) to `existing`.
    static func merge(existing: Data, tasks: [MeetingTask], country: String?) throws -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
            throw MergeError.notAnObject
        }
        guard object["tasks"] == nil else { throw MergeError.alreadyHasTasks }
        let encoded = try JSONEncoder().encode(tasks)
        object["tasks"] = try JSONSerialization.jsonObject(with: encoded)
        let existingCountry = (object["country"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let country, existingCountry?.isEmpty ?? true { object["country"] = country }
        return try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }
}
