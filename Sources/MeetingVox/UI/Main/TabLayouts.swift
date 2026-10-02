import SwiftUI

/// Two columns in a fixed ratio (the Resumen tab's 1.3fr / 1fr): the first
/// subview gets `ratio` parts, the second one part, `spacing` between them.
struct TwoColumns: Layout {
    /// The width assumed when a parent offers none (an "ideal size" query, as
    /// `fittingSize` makes): roughly the detail column at its default window
    /// size, so the height computed then is close to the real one.
    static let fallbackWidth: CGFloat = 640

    var ratio: CGFloat = 1.3
    var spacing: CGFloat = 22

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let usable = max(0, total - spacing)
        let first = usable * ratio / (ratio + 1)
        return (first, usable - first)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let total = proposal.width ?? Self.fallbackWidth
        let (a, b) = widths(total)
        let height = max(
            subviews[0].sizeThatFits(ProposedViewSize(width: a, height: nil)).height,
            subviews[1].sizeThatFits(ProposedViewSize(width: b, height: nil)).height
        )
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (a, b) = widths(bounds.width)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: a, height: bounds.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + a + spacing, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: b, height: bounds.height)
        )
    }
}

/// Wraps its subviews onto as many rows as the width needs (topic chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (positions, CGSize(width: usedWidth, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(subviews, width: bounds.width)
        for (subview, position) in zip(subviews, layout.positions) {
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }
}

/// A small uppercase section label (RESUMEN, TEMAS…).
struct TabLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(MainPalette.muted)
    }
}

/// A centred note for a tab with nothing to draw.
struct TabNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(MainPalette.muted)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
