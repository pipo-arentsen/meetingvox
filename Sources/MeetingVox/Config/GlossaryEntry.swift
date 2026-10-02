import Foundation

/// One glossary term (correct spelling) plus the ways the speech recognizer
/// tends to mis-transcribe it (e.g. MeetingVox ← "miting vox"). Variants are
/// always hints for the LLM prompts; with `transcript` (the default) they are
/// also replaced in the transcript itself once transcription finishes, the
/// original kept in `text_raw` (see `TranscriptGlossary`).
///
/// On disk (`config.json` → `glossary`) each element is either a plain string
/// (a term without variants, the original format) or
/// `{"term": "…", "variants": ["…"], "transcript": false}`. `transcript` is
/// written only when false, and an entry without variants and with the flag
/// on is written back as a plain string, so existing configs keep their shape.
struct GlossaryEntry: Equatable, Sendable {
    let term: String
    let variants: [String]
    /// "Corregir en la transcripción". A missing key counts as true.
    let transcript: Bool

    init(term: String, variants: [String] = [], transcript: Bool = true) {
        self.term = term
        self.variants = variants
        self.transcript = transcript
    }

    // MARK: Parsing

    /// Tolerant reading of one array element: a string or an object with a
    /// string `term`. Blank or non-string parts are dropped; nil when there
    /// is no usable term. A non-array `variants` counts as none, a non-bool
    /// `transcript` as true.
    init?(json: Any) {
        let rawTerm: Any?
        var rawVariants: [Any] = []
        var transcript = true
        if let string = json as? String {
            rawTerm = string
        } else if let object = json as? [String: Any] {
            rawTerm = object["term"]
            rawVariants = object["variants"] as? [Any] ?? []
            transcript = object["transcript"] as? Bool ?? true
        } else {
            return nil
        }
        guard let term = (rawTerm as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty
        else { return nil }
        self.init(
            term: term, variants: Self.clean(rawVariants.compactMap { $0 as? String }, term: term),
            transcript: transcript
        )
    }

    /// The whole `glossary` value: malformed elements are skipped, and a term
    /// repeated (case-insensitively) is merged into its first occurrence so
    /// every entry has a unique term (the UI keys rows by it).
    static func parse(_ raw: Any?) -> [GlossaryEntry] {
        var result: [GlossaryEntry] = []
        for element in raw as? [Any] ?? [] {
            guard let entry = GlossaryEntry(json: element) else { continue }
            if let i = result.firstIndex(where: { $0.term.caseInsensitiveCompare(entry.term) == .orderedSame }) {
                let first = result[i]
                result[i] = GlossaryEntry(
                    term: first.term, variants: clean(first.variants + entry.variants, term: first.term),
                    transcript: first.transcript
                )
            } else {
                result.append(entry)
            }
        }
        return result
    }

    /// Trimmed, non-empty, deduped case-insensitively (first spelling wins),
    /// and never the term itself — that would be no hint at all.
    static func clean(_ variants: [String], term: String) -> [String] {
        var seen: Set<String> = [term.lowercased()]
        var result: [String] = []
        for variant in variants {
            let v = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty, seen.insert(v.lowercased()).inserted else { continue }
            result.append(v)
        }
        return result
    }

    // MARK: Settings text field

    /// "miting vox, mitin vox" → ["miting vox", "mitin vox"].
    static func variants(from text: String) -> [String] {
        clean(text.components(separatedBy: ","), term: "")
    }

    /// Inverse of `variants(from:)`, for editing.
    var variantsText: String { variants.joined(separator: ", ") }

    // MARK: Writing

    /// A plain string for a bare term with the flag on (minimal diff for
    /// existing configs), an object otherwise; `transcript` only when false.
    var jsonValue: Any {
        if variants.isEmpty && transcript { return term }
        var object: [String: Any] = ["term": term]
        if !variants.isEmpty { object["variants"] = variants }
        if !transcript { object["transcript"] = false }
        return object
    }
}
