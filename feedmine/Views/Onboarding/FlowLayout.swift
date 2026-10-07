import SwiftUI

/// Simple horizontal wrapping layout with configurable spacing.
/// Shared by preference summary chips and language selection chips.
struct FlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    @Environment(\.layoutDirection) private var layoutDirection

    init(horizontalSpacing: CGFloat, verticalSpacing: CGFloat) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    /// Uniform spacing convenience.
    init(spacing: CGFloat) {
        self.init(horizontalSpacing: spacing, verticalSpacing: spacing)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            // The gap counts towards the fit test: `placeSubviews` breaks when the next chip would
            // cross the row edge *after* the spacing the previous chip already advanced, so measuring
            // without it returned one line where placement used two (width 100, chips 60 + 35,
            // spacing 10 → measured a single 105-wide line, placed as two rows).
            let spacing = lineWidth > 0 ? horizontalSpacing : 0
            if lineWidth + spacing + size.width > maxWidth && lineWidth > 0 {
                width = max(width, lineWidth)
                height += lineHeight + verticalSpacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += (lineWidth > 0 ? horizontalSpacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        width = max(width, lineWidth)
        height += lineHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            let placementX = layoutDirection == .rightToLeft
                ? bounds.maxX - (x - bounds.minX) - size.width  // mirror the row
                : x
            subview.place(at: CGPoint(x: placementX, y: y), proposal: .unspecified)
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
