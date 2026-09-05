import SwiftUI

/// Computes a poster grid's column count and per-item width from the
/// available container width.
///
/// Poster-card widths must always match the grid's actual column width —
/// see the git history on `CollectionGridView` for the bug that comes from
/// hardcoding a card width independent of the layout: a card narrower than
/// its column leaves extra gaps, a card wider than its column overlaps its
/// neighbor and eats the spacing entirely. Deriving `itemWidth` from the
/// container here guarantees an exact fit either way.
///
/// Column count is pinned to a minimum of 3 so narrow (iPhone-portrait-ish)
/// widths always show 3 columns rather than falling back to fewer, larger
/// ones; wider containers (landscape, iPad) grow past 3 toward
/// `idealItemWidth`-sized columns.
struct PosterGridMetrics {
    static let spacing: CGFloat = 16
    static let horizontalPadding: CGFloat = 16
    static let idealItemWidth: CGFloat = 130
    static let minimumColumns = 3

    let columnCount: Int
    let itemWidth: CGFloat

    /// `idealItemWidth` defaults to the portrait-poster value every existing
    /// caller (`CollectionGridView`) wants, but is overridable — `SearchView`
    /// passes its own `.regular`-size-class card widths (160/260, matching
    /// `MediaRailView`'s own scaled-up rail cards) so its iPad grid targets
    /// the same "deliberately bigger on iPad" sizing rather than this
    /// type's iPhone-oriented default. The fitting math itself doesn't care
    /// what the value represents (portrait vs. landscape tiles) — it only
    /// ever uses it as a target to solve column count from, then recomputes
    /// the real per-item width to exactly fill the container either way.
    init(containerWidth: CGFloat, idealItemWidth: CGFloat = Self.idealItemWidth, minimumColumns: Int = Self.minimumColumns) {
        let available = max(containerWidth - Self.horizontalPadding * 2, idealItemWidth)
        let fitCount = Int((available + Self.spacing) / (idealItemWidth + Self.spacing))
        columnCount = max(minimumColumns, fitCount)
        itemWidth = (available - Self.spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
    }

    var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(itemWidth), spacing: Self.spacing), count: columnCount)
    }
}
