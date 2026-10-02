import Foundation

/// Value of a Hindsight tag built from free text (`pais:<value>`,
/// `cliente:<value>`): case and diacritics folded, every run of characters
/// outside `[a-z0-9]` collapsed to a single `-`, leading and trailing `-`
/// trimmed. Nothing left (empty, punctuation only, non-Latin script) → nil, so
/// the tag is omitted rather than sent empty. Pure.
enum HindsightTagNormalizer {
    /// Longest value kept (the model may name a client at any length); a cut
    /// never leaves a trailing `-`.
    static let maxLength = 64

    static func value(_ text: String?) -> String? {
        guard let text else { return nil }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var result = ""
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            let isAlphanumeric = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            if isAlphanumeric {
                if pendingSeparator, !result.isEmpty { result.append("-") }
                pendingSeparator = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result.isEmpty ? nil : result
    }
}
