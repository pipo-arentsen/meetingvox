import Foundation

/// A minutes template: LLM instructions plus the Markdown skeleton of the
/// minutes to produce. Stored on disk as `<id>.md` with a small frontmatter:
///
///     ---
///     nombre: Minuta general
///     descripcion: Resumen estándar de cualquier reunión.
///     ---
///     <body>
///
/// `id` is the filename stem — the stable key used in config and in the
/// generated `minuta.<id>.md`, so renaming `nombre` never breaks references.
struct MinutesTemplate: Sendable, Equatable {
    let id: String
    let nombre: String
    let descripcion: String
    let cuerpo: String

    // MARK: - Parsing

    /// Parse a template file. Deliberately tolerant: these files are
    /// hand-edited, so a broken frontmatter degrades to "the whole file is
    /// the body" instead of hiding the template from the user.
    static func parse(id: String, contents: String) -> MinutesTemplate {
        // Normalize line endings first so files edited on Windows (or pasted
        // from the web) parse identically.
        let text = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = MinutesTemplate(id: id, nombre: id, descripcion: "", cuerpo: trimmed)

        var lines = trimmed.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return fallback }
        lines.removeFirst()
        guard let close = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return fallback }

        var fields: [String: String] = [:]
        for line in lines[..<close] {
            // Split on the first colon only, so values like "Cliente: X" survive.
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fields[key] = unquote(value)
        }

        let body = lines[(close + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nombre = fields["nombre"].flatMap { $0.isEmpty ? nil : $0 } ?? id
        return MinutesTemplate(
            id: id,
            nombre: nombre,
            descripcion: fields["descripcion"] ?? "",
            cuerpo: body
        )
    }

    /// Strip one pair of matching surrounding quotes (YAML habit).
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last,
              first == "\"" || first == "'"
        else { return value }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - Serialization

    /// On-disk representation; `parse(id:contents:)` round-trips it.
    var fileContents: String {
        "---\nnombre: \(nombre)\ndescripcion: \(descripcion)\n---\n\n\(cuerpo)\n"
    }
}
