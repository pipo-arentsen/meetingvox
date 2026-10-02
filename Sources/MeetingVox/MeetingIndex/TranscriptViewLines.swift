import Foundation

/// One line of the Transcripción tab: a run of one speaker's segments.
struct TranscriptViewLine: Equatable, Sendable, Identifiable {
    /// Position in the list (lines have no natural identity).
    let id: Int
    let startMs: Int
    /// The stable speaker id (`me` / `them`).
    let speaker: String
    let text: String
    /// What the glossary changed in `text` (UTF-16 ranges into it), carried
    /// through the merge of consecutive segments. Empty for a pre-v3
    /// transcript or a line the glossary left alone.
    var marks: [GlossaryMark] = []

    /// The hover text for the marks (`«miting vox» → MeetingVox; …`); nil
    /// when the line has none.
    var glossaryTooltip: String? { GlossaryMarks.tooltip(marks, in: text) }

    /// "Yo" / "Otros"; an unknown id shows as it is.
    var label: String { Textos.hablante(speaker) }
    /// `mm:ss`, or `h:mm:ss` past the hour.
    var timestamp: String { PromptBuilder.timestamp(startMs) }
    /// The textual form (`[mm:ss] Yo: …`), used only as the VoiceOver label of
    /// a line; the view draws the stamp, speaker and text in separate columns.
    var rendered: String { "[\(timestamp)] \(label): \(text)" }
}

/// Builds the tab's lines from `transcript.json` (DT-3). Pure apart from
/// `load`, which reads one folder.
///
/// Consecutive segments of the same speaker read as one turn, but a turn is
/// cut once merging would make it span more than `maxSpanMs`: a long monologue
/// stays scannable and each piece carries its own timestamp. A single segment
/// longer than that stays whole (its text cannot be cut at a time).
enum TranscriptViewLines {
    static let maxSpanMs = 60_000

    static func build(_ segments: [TranscriptInput.Segment]) -> [TranscriptViewLine] {
        struct Open {
            var startMs: Int
            var endMs: Int
            let speaker: String
            var text: String
            var marks: [GlossaryMark]
        }
        var closed: [Open] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let end = max(segment.end_ms ?? segment.start_ms, segment.start_ms)
            let marks = GlossaryMarks.marks(raw: segment.text_raw, text: text)
            if var last = closed.last, last.speaker == segment.speaker,
               max(last.endMs, end) - last.startMs <= maxSpanMs {
                last.endMs = max(last.endMs, end)
                // The second segment's marks move past the first's text and
                // the joining space (UTF-16, like the marks themselves).
                let shift = last.text.utf16.count + 1
                last.marks += marks.map { GlossaryMark(location: $0.location + shift, length: $0.length, original: $0.original) }
                last.text += " " + text
                closed[closed.count - 1] = last
            } else {
                closed.append(Open(startMs: segment.start_ms, endMs: end, speaker: segment.speaker, text: text, marks: marks))
            }
        }
        return closed.enumerated().map {
            TranscriptViewLine(
                id: $0.offset, startMs: $0.element.startMs, speaker: $0.element.speaker,
                text: $0.element.text, marks: $0.element.marks
            )
        }
    }

    /// The session's lines; nil when `transcript.json` is missing or not
    /// readable (an empty list is a transcript with no text).
    static func load(from dir: URL) -> [TranscriptViewLine]? {
        (try? TranscriptInput.read(from: dir)).map { build($0.segments) }
    }
}

/// The line a search hit asks the Transcripción tab to scroll to and mark
/// (`TranscriptViewLine.id` of that session's lines).
struct TranscriptTarget: Equatable, Sendable {
    let dir: URL
    let lineID: Int
    /// Bumped by every tap, so tapping the same snippet again is a new target
    /// (the tab's `.task(id:)` restarts and scrolls back to the line).
    var nonce = 0
}

/// What the Transcripción tab shows. Pure.
enum TranscriptTabState: Equatable {
    /// The session's data is still being read.
    case loading
    /// No `transcript.json` (not transcribed yet, or transcription is off).
    case missing
    /// The file is there and could not be read.
    case unreadable
    /// The file has no text.
    case empty
    case lines([TranscriptViewLine])

    /// - Parameters:
    ///   - hasTranscript: `transcript.json` exists (the list's scan).
    ///   - loaded: the detail's off-main read has arrived.
    ///   - lines: `SessionDetailData.transcriptLines`.
    static func derive(hasTranscript: Bool, loaded: Bool, lines: [TranscriptViewLine]?) -> TranscriptTabState {
        guard hasTranscript else { return .missing }
        guard loaded else { return .loading }
        guard let lines else { return .unreadable }
        return lines.isEmpty ? .empty : .lines(lines)
    }
}
