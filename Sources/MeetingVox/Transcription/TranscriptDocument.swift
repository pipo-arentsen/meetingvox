import Foundation

/// transcript.json as quill writes it, and transcript.md rendered from it.
/// Property names are the JSON schema — stable, since `on_stop` consumers
/// parse it. `text_raw` is the only addition: the recognizer's
/// text before the glossary corrected `text`; absent in transcripts older
/// than v3 and in any segment written without the glossary step. Everything
/// but `segments` is optional so rewriting an older file ("Aplicar
/// glosario") never fails on a missing key.
struct TranscriptDocument: Codable, Sendable, Equatable {
    struct Segment: Codable, Sendable, Equatable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int?
        var text: String
        var text_raw: String?
    }

    let engine: String?
    let model: String?
    let created_at: String?
    var segments: [Segment]

    static func read(from dir: URL) throws -> TranscriptDocument {
        let data = try Data(contentsOf: dir.appendingPathComponent(SessionFiles.transcriptJSON))
        return try JSONDecoder().decode(TranscriptDocument.self, from: data)
    }

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent(SessionFiles.transcriptJSON), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent(SessionFiles.transcriptMD), options: .atomic)
    }

    /// transcript.md: the corrected `text` only.
    func rendered(title: String) -> String {
        var lines = ["# \(title)", ""]
        if let engine, let model {
            lines += [Textos.motor(engine, model), ""]
        }
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(Textos.hablante(seg.speaker)):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
