import SwiftUI

/// A row laid out like an `HStack`, except that a view which would cross
/// `gap` starts just past it instead, so no control sits on an iPhone Duo's
/// fold. The views before the gap keep their places; it only moves the first
/// one that would reach it, and the rest follow. The collection grids' filter
/// pills use it: held wide, Favorites straddled the fold (Benjamin,
/// 2026-10-31).
///
/// A view marked `.foldGapApplied()` is never moved: it is a group that kept
/// the gap among its own views (the pills, which share one glass container),
/// placed by an outer row that only needs to keep the views after it clear.
struct FoldGapHStack: Layout {
    var spacing: CGFloat
    /// The span to keep clear, in this row's own coordinates (0 at its leading
    /// edge), or `nil` to lay out as a plain `HStack`.
    var gap: ClosedRange<CGFloat>?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let offsets = offsets(for: sizes, subviews: subviews)
        return CGSize(
            width: (offsets.last ?? 0) + (sizes.last?.width ?? 0),
            height: sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        for (subview, (offset, size)) in zip(subviews, zip(offsets(for: sizes, subviews: subviews), sizes)) {
            subview.place(
                at: CGPoint(x: bounds.minX + offset, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(size)
            )
        }
    }

    private func offsets(for sizes: [CGSize], subviews: Subviews) -> [CGFloat] {
        Self.offsets(widths: sizes.map(\.width), movable: subviews.map { !$0[FoldGapAppliedKey.self] }, spacing: spacing, gap: gap)
    }

    /// Each view's leading edge, in the row's coordinates.
    static func offsets(widths: [CGFloat], movable: [Bool]? = nil, spacing: CGFloat, gap: ClosedRange<CGFloat>?) -> [CGFloat] {
        var x: CGFloat = 0
        var offsets: [CGFloat] = []
        for (index, width) in widths.enumerated() {
            if index > 0 { x += spacing }
            if let gap, movable?[index] ?? true, x < gap.upperBound, x + width > gap.lowerBound {
                x = gap.upperBound
            }
            offsets.append(x)
            x += width
        }
        return offsets
    }
}

private struct FoldGapAppliedKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Tells an enclosing `FoldGapHStack` this view kept its gap itself; see
    /// `FoldGapHStack`.
    func foldGapApplied() -> some View {
        layoutValue(key: FoldGapAppliedKey.self, value: true)
    }
}
