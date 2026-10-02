import Foundation

/// A GFM table: `columnCount` (the header's) columns, every row padded or
/// merged to exactly that many cells. Cell text is raw inline markdown.
struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case none, leading, center, trailing }

    let alignments: [Alignment]
    let header: [String]
    let rows: [[String]]

    var columnCount: Int { header.count }
}

enum MarkdownListMarker: Equatable, Sendable {
    case bullet
    case number(Int)
}

/// One block of a rendered markdown document. Text fields hold the raw
/// inline markdown (`**bold**`, links…); `MarkdownInline` turns them into
/// styled text at render time.
enum MarkdownBlock: Equatable, Sendable {
    /// `level` 1...6 as written; h5 and h6 render like h4 (`displayLevel`).
    case heading(level: Int, text: String)
    case paragraph(String)
    /// A flat list item: nesting is its `level` (0...3), so the renderer
    /// stays a plain `ForEach`.
    case listItem(MarkdownListMarker, level: Int, text: String)
    case table(MarkdownTable)
    case rule
    case code(language: String?, text: String)

    /// The heading style a level renders with: h5/h6 look like h4.
    static func displayLevel(_ level: Int) -> Int { min(level, 4) }
}

/// Block parser for the minutes viewer (MD-1..5). Pure and total: it never
/// throws and never drops text — anything it does not recognise (HTML,
/// comments, blockquotes, malformed tables, an unclosed fence) becomes a
/// paragraph holding the original text.
///
/// Deliberately small: no dependency, and `AttributedString` has no tables.
enum MarkdownBlocks {
    /// The first line of every `minuta.md` (`MinutesCoordinator.provenance`).
    /// Only a *first* line starting with this is stripped; any other comment
    /// is content.
    static let provenancePrefix = "<!-- quill minutes"

    /// Deepest list level; anything nested further stays at this level.
    static let maxListLevel = 3

    static func parse(_ source: String) -> [MarkdownBlock] {
        var lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        if let first = lines.first, first.hasPrefix(provenancePrefix) { lines.removeFirst() }
        var parser = Parser(lines: lines)
        return parser.run()
    }

    // MARK: - Line classification

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Leading whitespace width; a tab counts as four spaces.
    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 } else if ch == "\t" { width += 4 } else { break }
        }
        return width
    }

    private struct Fence {
        let char: Character
        let length: Int
        let info: String

        init?(_ line: String) {
            guard indentWidth(line) <= 3 else { return nil }
            let body = line.drop { $0 == " " }
            guard let char = body.first, char == "`" || char == "~" else { return nil }
            let run = body.prefix { $0 == char }
            guard run.count >= 3 else { return nil }
            let info = body.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            guard !(char == "`" && info.contains("`")) else { return nil }
            (self.char, length, self.info) = (char, run.count, info)
        }

        func closes(_ line: String) -> Bool {
            guard indentWidth(line) <= 3 else { return false }
            let body = line.drop { $0 == " " }
            let run = body.prefix { $0 == char }
            return run.count >= length && body.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
        }
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        guard indentWidth(line) <= 3 else { return nil }
        let body = line.drop { $0 == " " }
        let hashes = body.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = body.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // An optional closing run of #s, separated by a space: "## Título ##".
        if let range = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? nil : (hashes.count, text)
    }

    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (marker: MarkdownListMarker, indent: Int, text: String)? {
        let indent = indentWidth(line)
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first else { return nil }

        let marker: MarkdownListMarker
        var rest: Substring
        if "-*+".contains(first) {
            marker = .bullet
            rest = body.dropFirst()
        } else if first.isASCII, first.isNumber {
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            let after = body.dropFirst(digits.count)
            guard (1...9).contains(digits.count), let delimiter = after.first, delimiter == "." || delimiter == ")",
                  let number = Int(digits)
            else { return nil }
            marker = .number(number)
            rest = after.dropFirst()
        } else {
            return nil
        }
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (marker, indent, text)
    }

    // MARK: - Tables

    /// Cells of a table row, and whether the line had an unescaped pipe at
    /// all. `\|` becomes a literal `|` inside its cell.
    private static func splitRow(_ line: String) -> (cells: [String], hasPipe: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var current = ""
        var escaped = false
        var sawSeparator = false
        var endedWithSeparator = false
        for ch in trimmed {
            endedWithSeparator = false
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current)
                current = ""
                sawSeparator = true
                endedWithSeparator = true
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        guard sawSeparator else { return ([trimmed], false) }
        if trimmed.hasPrefix("|") { cells.removeFirst() }
        if endedWithSeparator { cells.removeLast() }
        return (cells.map { $0.trimmingCharacters(in: .whitespaces) }, true)
    }

    private static func alignments(delimiter line: String) -> [MarkdownTable.Alignment]? {
        let (cells, hasPipe) = splitRow(line)
        guard hasPipe, !cells.isEmpty else { return nil }
        var result: [MarkdownTable.Alignment] = []
        for cell in cells {
            let leading = cell.hasPrefix(":"), trailing = cell.hasSuffix(":")
            let dashes = cell.dropFirst(leading ? 1 : 0).dropLast(trailing && cell.count > (leading ? 1 : 0) ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(leading && trailing ? .center : leading ? .leading : trailing ? .trailing : MarkdownTable.Alignment.none)
        }
        return result
    }

    /// Cells beyond the header's are kept, joined into the last column, so a
    /// ragged row never loses text; missing cells are empty.
    private static func normalized(_ cells: [String], to count: Int) -> [String] {
        if cells.count <= count { return cells + Array(repeating: "", count: count - cells.count) }
        var head = Array(cells.prefix(count - 1))
        head.append(cells.dropFirst(count - 1).joined(separator: " | "))
        return head
    }

    // MARK: - Parser

    private struct Parser {
        let lines: [String]
        private var blocks: [MarkdownBlock] = []
        private var i = 0
        /// Indent widths of the open list levels (kept across blank lines,
        /// reset by any other block).
        private var listIndents: [Int] = []
        /// The previous block is a list item with no blank line since: a
        /// following plain line continues it.
        private var inList = false

        init(lines: [String]) { self.lines = lines }

        mutating func run() -> [MarkdownBlock] {
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    inList = false
                    i += 1
                } else if let fence = Fence(line) {
                    codeBlock(opening: fence)
                } else if let (level, text) = heading(line) {
                    emit(.heading(level: level, text: text))
                    i += 1
                } else if isRule(line) {
                    emit(.rule)
                    i += 1
                } else if let table = table(at: i) {
                    emit(.table(table.table))
                    i = table.next
                } else if let item = listItem(line) {
                    listItemBlock(item)
                    i += 1
                } else {
                    plainLines()
                }
            }
            return blocks
        }

        private mutating func emit(_ block: MarkdownBlock) {
            blocks.append(block)
            listIndents = []
            inList = false
        }

        private mutating func codeBlock(opening fence: Fence) {
            var j = i + 1
            while j < lines.count, !fence.closes(lines[j]) { j += 1 }
            if j < lines.count {
                emit(.code(language: fence.info.isEmpty ? nil : fence.info, text: lines[(i + 1)..<j].joined(separator: "\n")))
                i = j + 1
            } else {
                // Unclosed: keep every original line, verbatim, to the end.
                emit(.paragraph(lines[i...].joined(separator: "\n")))
                i = lines.count
            }
        }

        private mutating func listItemBlock(_ item: (marker: MarkdownListMarker, indent: Int, text: String)) {
            while let top = listIndents.last, item.indent < top { listIndents.removeLast() }
            if listIndents.last != item.indent { listIndents.append(item.indent) }
            let level = min(listIndents.count - 1, MarkdownBlocks.maxListLevel)
            blocks.append(.listItem(item.marker, level: level, text: item.text))
            inList = true
        }

        /// Plain lines up to a blank line or the start of another block: a
        /// paragraph, or the continuation of the list item just above.
        private mutating func plainLines() {
            var text: [String] = []
            var j = i
            while j < lines.count, !isBlank(lines[j]), j == i || !startsBlock(at: j) {
                text.append(lines[j].trimmingCharacters(in: .whitespaces))
                j += 1
            }
            let joined = text.joined(separator: "\n")
            if inList, case .listItem(let marker, let level, let existing)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker, level: level, text: existing + "\n" + joined)
            } else {
                emit(.paragraph(joined))
            }
            i = j
        }

        private func startsBlock(at index: Int) -> Bool {
            let line = lines[index]
            return Fence(line) != nil || heading(line) != nil || isRule(line) || listItem(line) != nil
                || table(at: index) != nil
        }

        private func table(at index: Int) -> (table: MarkdownTable, next: Int)? {
            guard index + 1 < lines.count else { return nil }
            let header = splitRow(lines[index])
            guard header.hasPipe, !header.cells.isEmpty, let alignments = alignments(delimiter: lines[index + 1]),
                  alignments.count == header.cells.count
            else { return nil }
            var rows: [[String]] = []
            var j = index + 2
            while j < lines.count, !isBlank(lines[j]), Fence(lines[j]) == nil, heading(lines[j]) == nil {
                let row = splitRow(lines[j])
                guard row.hasPipe, !row.cells.isEmpty else { break }
                rows.append(normalized(row.cells, to: header.cells.count))
                j += 1
            }
            return (MarkdownTable(alignments: alignments, header: header.cells, rows: rows), j)
        }
    }
}
