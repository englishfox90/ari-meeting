//
//  MarginaliaFlowLayout.swift — a left-to-right wrapping layout (children flow onto the next
//  line when the row runs out of width). SwiftUI ships no built-in flow container; the
//  referenced-moments chip row and inline citation chips in the summary both need one.
//
//  Lives in AriKit (not the app target) because `MarginaliaMarkdownView` — also in AriKit —
//  uses it to interleave word tokens with tappable citation chips.
//
import SwiftUI

public struct MarginaliaFlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = 8, lineSpacing: CGFloat? = nil) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        let maxWidth = proposal.width ?? bounds.width
        var y = bounds.minY
        // Buffer each row so we know its height before placing — items are then centered on the
        // row's midline (a tall citation chip and a short text word share one baseline band)
        // instead of every item hugging the top.
        var row: [(subview: LayoutSubview, size: CGSize, x: CGFloat)] = []
        var rowWidth: CGFloat = 0

        func flushRow() {
            let rowHeight = row.reduce(0) { max($0, $1.size.height) }
            for item in row {
                let itemY = y + (rowHeight - item.size.height) / 2
                item.subview.place(
                    at: CGPoint(x: item.x, y: itemY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
            }
            y += rowHeight + lineSpacing
            row.removeAll(keepingCapacity: true)
            rowWidth = 0
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                flushRow()
            }
            let x = bounds.minX + rowWidth + (rowWidth > 0 ? spacing : 0)
            row.append((subview, size, x))
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
        }
        flushRow()
    }
}
