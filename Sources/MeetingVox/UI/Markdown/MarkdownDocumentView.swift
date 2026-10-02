import SwiftUI

/// Renders a parsed markdown document (the Minuta tab, the template
/// preview). Takes only the text or blocks it is given — no config, no
/// disk — so it renders identically in the app and in the headless
/// snapshots. Reading width is capped at `readingWidth`; wide tables scroll
/// horizontally instead of stretching the column.
struct MarkdownDocumentView: View {
    static let readingWidth: CGFloat = 660

    let blocks: [MarkdownBlock]

    init(text: String) {
        blocks = MarkdownParseCache.shared.blocks(for: text)
    }

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: Self.readingWidth, alignment: .leading)
        .textSelection(.enabled)
        // Links come from model-written text: open only http(s) and mailto.
        .environment(\.openURL, OpenURLAction { url in
            MarkdownInline.isAllowedLink(url) ? .systemAction : .discarded
        })
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownInline.attributed(text))
                .font(Self.headingFont(MarkdownBlock.displayLevel(level)))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(MarkdownInline.attributed(text))
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let level, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.markerText(marker))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(MarkdownInline.attributed(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 18)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Divider().padding(.vertical, 4)
        case .code(_, let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private static func headingFont(_ displayLevel: Int) -> Font {
        switch displayLevel {
        case 1: .title.weight(.bold)
        case 2: .title2.weight(.semibold)
        case 3: .title3.weight(.semibold)
        default: .headline
        }
    }

    private static func markerText(_ marker: MarkdownListMarker) -> String {
        switch marker {
        case .bullet: "•"
        case .number(let n): "\(n)."
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        Text(MarkdownInline.attributed(cell))
                            .fontWeight(.semibold)
                            .gridColumnAlignment(Self.alignment(table.alignments[column]))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownInline.attributed(cell))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private static func alignment(_ alignment: MarkdownTable.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .none, .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
