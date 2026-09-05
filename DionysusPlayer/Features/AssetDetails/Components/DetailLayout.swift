import SwiftUI

/// Shared layout rules for the asset detail pages. The sibling of
/// `SettingsLayout`, which covers the Profile screens — and explains why
/// *those* test both size classes where everything here tests width alone.
enum DetailLayout {
    /// Cap for a detail page's metadata/actions/tabs column on regular
    /// width — see `readableDetailColumn()`.
    ///
    /// Derived from measured rendering rather than a round number, the same
    /// way `SettingsLayout.readableFooterWidth` is: a 178-character synopsis
    /// wraps after 105 characters at 773.5pt of `.body`, i.e. ~7.37pt per
    /// character, so the conventional 75-character maximum is ~552pt of
    /// text. 600 rather than 552 because it bounds the column *including*
    /// its 16pt gutters (568pt of text, ~77 characters) — sizing the column
    /// rather than the text is what lets one number also govern the Play row
    /// and the segmented picker sharing it.
    static let readableContentWidth: CGFloat = 600

    /// Corner radius of the tabbed-content panel. Sits between the system's
    /// grouped-list card radius and the larger radii iOS 26 favours, and
    /// stays outside the 12pt radius of the Play button above it.
    static let panelCornerRadius: CGFloat = 16

    /// Inset between the tabbed-content panel's edge and its contents.
    static let panelPadding: CGFloat = 16
}

/// Constrains a detail page's metadata/actions/tabs column to a readable
/// measure on regular width, leading-aligned.
///
/// Unconstrained the column runs the full page (820pt iPad portrait, 1180pt
/// landscape) and three things fail together: the synopsis reaches ~105 and
/// ~160 characters per line against a 45–75 optimum, the Play button
/// stretches to 720/1080pt against HIG's "avoid full-width buttons", and
/// `SummaryRow` pushes label and value ~1,100pt apart.
///
/// Deliberately not applied to the hero or the rails either side of it —
/// a full-bleed image and horizontally scrolling cards are the two things
/// that genuinely use the width. Only the fixed-width-hungry middle column
/// is capped.
///
/// Two `.frame`s: the inner caps the width and keeps contents leading-
/// aligned against that cap, the outer centres the capped column in the
/// page. Centring breaks alignment with the full-bleed rails below, which
/// still start at the leading margin — but the alternative puts all 580pt of
/// slack on one side in iPad landscape, which reads as a failed layout
/// rather than a deliberate measure, and the hero above already centres its
/// own logo.
///
/// Gated on horizontal size class alone, matching the Home/Search/Downloads
/// grids rather than the settings screens' stricter AND: a 932pt iPhone Pro
/// Max in landscape wants a capped text column just as much, and nothing
/// here depends on the screen also being tall.
private struct ReadableDetailColumn: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.frame(
            maxWidth: horizontalSizeClass == .regular ? DetailLayout.readableContentWidth : .infinity,
            alignment: .leading
        )
        // Centers the capped column itself. A no-op on compact width,
        // where the frame above already fills the page.
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    /// See `ReadableDetailColumn`. No-op on compact width, so it's safe
    /// to apply unconditionally to any detail page's content column.
    func readableDetailColumn() -> some View {
        modifier(ReadableDetailColumn())
    }
}

/// Gives a detail page's tabbed content (`DetailTabsView`, and its offline
/// counterpart `DownloadedDetailTabsView`) its own panel, so About/Cast &
/// Crew/Details reads as one area rather than loose text after the Play
/// button.
///
/// Deliberately a plain filled card, not Liquid Glass: glass is the system's
/// *functional* layer, and Apple's guidance is explicit that content-layer
/// elements shouldn't use it. A panel of synopsis and codec rows is content.
///
/// `secondarySystemBackground` rather than a hand-picked grey, so the panel
/// tracks light/dark and the system's contrast settings for free. Note this
/// inverts the usual grouped-list relationship (a light card on a grey
/// page): these pages sit on `systemBackground`, and repainting the whole
/// page grey would drag the hero and rails along for one panel's benefit.
///
/// Applies at every size class, unlike `readableDetailColumn()` — the
/// grouping is worth as much on a phone. One asymmetry: the panel's inset
/// eats into the text column, so on compact the tabbed content sits
/// narrower than the Play button above it, where on regular width they line
/// up exactly.
private struct DetailTabsPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(DetailLayout.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: DetailLayout.panelCornerRadius, style: .continuous
                )
                .fill(Color(.secondarySystemBackground))
            )
    }
}

extension View {
    /// See `DetailTabsPanel`.
    func detailTabsPanel() -> some View {
        modifier(DetailTabsPanel())
    }
}

/// Column count, per-row width and artwork size for a detail page's own list
/// of child items — `SeasonEpisodeList`'s episodes, `CollectionItemList`'s
/// movies, `PlaylistItemList`'s members.
///
/// A single full-width row wastes most of an iPad's width: measured on an
/// 11-inch, an episode row's text ran 601pt portrait / 961pt landscape while
/// staying 71pt tall, leaving the chevron ~1,000pt from its artwork. Two
/// columns fix the measure without shrinking the list's footprint — unlike
/// the metadata column above, which is capped instead. The distinction is
/// what the width is *for*: a paragraph gains nothing from it, a list gains
/// another item.
///
/// The artwork scales because a fixed 160pt thumbnail is 187pt of a row once
/// the accent bar and spacing count, which a 386pt half-width row can't
/// absorb — it would leave ~38 characters of `.caption`, tighter than the
/// single-column layout this replaces. Sizing artwork from its row (as
/// `PosterGridMetrics` does for poster grids) keeps text workable at every
/// width:
///
/// | container | columns | row | 16:9 thumb | poster |
/// | --- | --- | --- | --- | --- |
/// | iPhone portrait, 402pt | 1 | 370pt | 160x90 | 90x135 |
/// | iPhone Pro Max landscape, 932pt | 2 | 442pt | 133x75 | 97x146 |
/// | iPad portrait, 820pt | 2 | 386pt | 120x68 | 90x135 |
/// | iPad landscape, 1180pt | 2 | 566pt | 170x96 | 125x188 |
///
/// `rowWidth` is what each column *will* be given, solved rather than read
/// back from the grid — see `columns`. The single-column case keeps each
/// list's established artwork size rather than deriving it, so compact width
/// renders exactly as it did before this type existed.
struct DetailRowGridMetrics {
    /// How one list's artwork is sized. A per-list value rather than
    /// constants on this type because a 16:9 still and a 2:3 poster agree on
    /// none of these numbers — and a poster that already starts small has
    /// nothing to give back on a narrow row the way a 160pt thumbnail does.
    struct Artwork {
        /// Kept as-is whenever `columnCount` is 1.
        let singleColumnWidth: CGFloat
        /// Height as a multiple of width — 9/16 for a still, 1.5 for a
        /// portrait poster.
        let heightRatio: CGFloat
        /// Share of the row the artwork takes on multi-column, before the
        /// clamps below.
        let widthFraction: CGFloat
        /// The floor keeps a narrow two-column row's artwork recognisable;
        /// the ceiling stops a 13-inch iPad in landscape turning a thumbnail
        /// into a poster.
        let minimumWidth: CGFloat
        let maximumWidth: CGFloat

        /// The 16:9 still shared by `SeasonEpisodeList` and
        /// `PlaylistItemList` — the latter uses the same landscape shape for
        /// every row regardless of kind, so a Movie in a playlist sizes from
        /// this rather than `poster`.
        static let landscapeThumbnail = Artwork(
            singleColumnWidth: 160, heightRatio: 9 / 16,
            widthFraction: 0.3, minimumWidth: 120, maximumWidth: 200
        )

        /// `CollectionItemList`'s 2:3 movie poster. Smaller fraction than the
        /// thumbnail, and a floor equal to its own single-column width: 90pt
        /// is already the smallest a poster stays legible at, so a
        /// two-column row can only grow it.
        static let poster = Artwork(
            singleColumnWidth: 90, heightRatio: 1.5,
            widthFraction: 0.22, minimumWidth: 90, maximumWidth: 130
        )
    }

    /// Both the gap between columns and, via each list's own
    /// `.padding(.horizontal)`, the list's outer margin.
    static let spacing: CGFloat = 16
    static let horizontalPadding: CGFloat = 16

    /// A second column has to be worth having. Below this a row can't hold
    /// artwork plus enough text to beat the full-width layout, so the list
    /// stays single-column — which is also where a zero `containerWidth`
    /// (the first frame, before `.onGeometryChange` reports) lands.
    static let minimumRowWidth: CGFloat = 320

    let columnCount: Int
    let rowWidth: CGFloat
    let artworkWidth: CGFloat
    let artworkHeight: CGFloat

    /// `.flexible`, **not** `.fixed` — despite `rowWidth` already being
    /// solved to fill the container exactly, and despite `PosterGridMetrics`
    /// using `.fixed` for the same job.
    ///
    /// The difference is where the width comes from. `PosterGridMetrics`'
    /// callers read it from a `GeometryReader` wrapped *around* their
    /// `ScrollView`, beyond the grid's influence. These lists have no such
    /// vantage point — each is one child inside a detail page's scroll
    /// content — so they measure themselves, and `.fixed` closes that into a
    /// loop: fixed columns give the grid a hard minimum width, the grid
    /// raises its container to meet it, and the container is what gets
    /// measured.
    ///
    /// Observed live (iPad, 2026-09-04): rotating landscape → portrait left
    /// the page stuck at 1180pt inside an 820pt window, hero and list shifted
    /// 180pt off the leading edge permanently, because the 2 × 566pt grid
    /// kept re-asserting the width that produced it. `.flexible` has no
    /// meaningful minimum, so the measurement stays honest.
    var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top),
            count: columnCount
        )
    }

    /// Gated on horizontal size class *as well as* measured width, matching
    /// `ReadableDetailColumn`: an iPhone Pro Max in landscape is regular
    /// width and fits two columns, but a compact-width container that happens
    /// to be wide (a narrow Split View pane) is one the system already treats
    /// as a phone.
    init(containerWidth: CGFloat, isRegularWidth: Bool, artwork: Artwork) {
        let available = max(containerWidth - Self.horizontalPadding * 2, 0)
        let fitsTwoColumns = available >= Self.minimumRowWidth * 2 + Self.spacing
        columnCount = isRegularWidth && fitsTwoColumns ? 2 : 1
        rowWidth = (available - Self.spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        artworkWidth = columnCount == 1
            ? artwork.singleColumnWidth
            : min(
                max((rowWidth * artwork.widthFraction).rounded(), artwork.minimumWidth),
                artwork.maximumWidth
            )
        artworkHeight = (artworkWidth * artwork.heightRatio).rounded()
    }
}
