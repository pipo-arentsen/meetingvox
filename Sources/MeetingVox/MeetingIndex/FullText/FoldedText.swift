import Foundation

/// A string folded like `MeetingFilter.normalize` (case and diacritics), with
/// a map from every folded UTF-16 unit back to the ORIGINAL characters it came
/// from, so a match found in folded text can be highlighted in the text the
/// user reads. Pure. Folding goes character by character (a `ß` becomes `ss`,
/// both units map to the one original character), so a range always covers
/// whole characters of the original.
///
/// Built only for the one line a snippet is cut from; the index itself folds
/// whole strings.
struct FoldedText: Sendable {
    let folded: String
    /// Per folded UTF-16 unit: where its source character starts / ends in the original.
    private let starts: [Int]
    private let ends: [Int]

    init(_ original: String) {
        var out = ""
        var starts: [Int] = []
        var ends: [Int] = []
        var offset = 0
        for character in original {
            let piece = String(character)
            let length = piece.utf16.count
            let folded = MeetingFilter.normalize(piece)
            for _ in folded.utf16 {
                starts.append(offset)
                ends.append(offset + length)
            }
            out += folded
            offset += length
        }
        self.folded = out
        self.starts = starts
        self.ends = ends
    }

    /// Every non-overlapping occurrence of an already-folded `token`, as
    /// UTF-16 ranges into the original string. Empty for an empty token.
    func originalRanges(of token: String) -> [NSRange] {
        guard !token.isEmpty else { return [] }
        let haystack = folded as NSString
        var result: [NSRange] = []
        var from = 0
        while from < haystack.length {
            let found = haystack.range(
                of: token, options: .literal, range: NSRange(location: from, length: haystack.length - from)
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            let start = starts[found.location]
            let end = ends[found.location + found.length - 1]
            result.append(NSRange(location: start, length: end - start))
            from = found.location + found.length
        }
        return result
    }
}
