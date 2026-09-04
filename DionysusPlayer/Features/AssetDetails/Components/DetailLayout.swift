import SwiftUI

/// Shared layout rules for the asset detail pages.
///
/// The sibling of `SettingsLayout` for the other half of the app — see
/// that type for the Profile screens' equivalent, and for why *those*
/// screens test both size classes while everything here tests width
/// alone.
enum DetailLayout {
    /// Cap for a detail page's metadata/actions/tabs column on regular
    /// width — see `readableDetailColumn()`.
    ///
    /// Derived the same way `SettingsLayout.readableFooterWidth` is,
    /// from this app's own measured rendering rather than a round
    /// number. Elemental's 178-character synopsis wraps after 105
    /// characters at a measured 773.5pt of `.body` text, i.e. ~7.37pt
    /// per character. The conventional readable maximum is 75
    /// characters, so 75 x 7.37 ~= 552pt of *text*.
    ///
    /// This constant is 600 rather than 552 because it bounds the
    /// column including its own 16pt gutters: 600 - 32 = 568pt of text,
    /// or ~77 characters, which is the 75-character target within a
    /// couple of characters. Sizing the column instead of the text is
    /// what lets the same number also govern the Play row and the
    /// segmented picker that share it.
    static let readableContentWidth: CGFloat = 600

    /// Corner radius of the tabbed-content panel — see
    /// `detailTabsPanel()`. Sits between the system's own grouped-list
    /// card radius and the larger radii iOS 26 favours, and stays
    /// comfortably outside the 12pt radius of the Play button that
    /// shares the column above it.
    static let panelCornerRadius: CGFloat = 16

    /// Inset between the tabbed-content panel's edge and its contents.
    static let panelPadding: CGFloat = 16
}

/// Constrains a detail page's metadata/actions/tabs column to a readable
/// measure on regular width, leading-aligned.
///
/// Unconstrained, that column runs the full width of the page — measured
/// at 820pt in iPad portrait and 1180pt in landscape on an 11-inch
/// device. Three separate things go wrong at once at those widths, all
/// of them the same root cause:
///
/// - The synopsis reaches ~105 characters per line in portrait and ~160
///   in landscape, against a 45-75 optimum. Apple's own guidance is that
///   system layout guides exist partly to "restrict the width of text
///   for optimal readability".
/// - The Play button stretches to 720pt (portrait) / 1080pt
///   (landscape). HIG's Layout guidance for touch platforms is explicit:
///   "Avoid full-width buttons."
/// - `TechnicalDetailsView`'s `SummaryRow` pushes its label and value to
///   opposite screen edges, leaving ~1,100pt of horizontal scan between
///   "Container" and "MKV" in landscape — the same defect the Profile
///   screen had before its split layout, which has no split here to
///   solve it.
///
/// Deliberately *not* applied to the hero header or to the
/// chapter/collection/similar rails either side of it. Those are the two
/// kinds of content that genuinely use the extra width: a full-bleed
/// image, and horizontally scrolling rails that simply show more cards.
/// Only the fixed-width-hungry middle column is capped.
///
/// The column is centered in the page; its *contents* stay
/// leading-aligned within it. Two `.frame`s rather than one: the inner
/// one caps the width and keeps text left-aligned against that cap, the
/// outer one takes the full page width and places the capped column in
/// the middle of it.
///
/// This deliberately breaks alignment with the full-bleed rails below,
/// which still start at the leading margin. Centering won out because
/// the alternative leaves every bit of the slack on one side — 580pt of
/// empty page to the right of the column in iPad landscape, which reads
/// as the layout having failed rather than as a deliberate measure.
/// Balanced margins read as intentional, and the hero directly above
/// the column already centers its own logo, so the column has something
/// to line up with even though the rails don't.
///
/// Gated on horizontal size class alone, matching the Home/Search/
/// Downloads grids rather than the settings screens' stricter AND of
/// both: an iPhone Pro Max in landscape is 932pt wide, where a capped
/// text column is just as welcome as it is on an iPad, and nothing here
/// depends on the screen also being tall.
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

/// Gives a detail page's tabbed content (`DetailTabsView`) its own
/// panel, so About/Cast & Crew/Details reads as one distinct area
/// rather than as loose text following the Play button.
///
/// Deliberately a plain filled card, not Liquid Glass. Glass is the
/// system's *functional* layer — the tab bar and toolbar floating above
/// this page already use it — and Apple's guidance is explicit that
/// content-layer elements shouldn't: "Don't use Liquid Glass in the
/// content layer... Including it in the content layer creates
/// unnecessary complexity and confusing visual hierarchy," with
/// standard materials named as the right tool for structure beneath the
/// glass layer. A tab panel full of synopsis and codec rows is content.
///
/// `secondarySystemBackground` rather than a hand-picked grey so the
/// panel tracks light/dark mode and the system's own contrast settings
/// for free. Note this inverts the usual grouped-list relationship (a
/// light card on a grey page): these detail pages sit on
/// `systemBackground`, and repainting the whole page grey to get the
/// conventional direction would drag the hero and the rails along with
/// it for one panel's benefit.
///
/// Applies at every size class, unlike `readableDetailColumn()` above.
/// It was built regular-width-only and trialled on a physical iPhone
/// before being opened up, on the grounds that the grouping it provides
/// — tabs and their content reading as one component rather than as
/// loose text following the Play button — is worth just as much on a
/// 402pt-wide phone as on an iPad. The one asymmetry to be aware of:
/// the panel's inset eats into the text column, so on compact the
/// tabbed content sits visually narrower than the Play button above it,
/// where on regular width the two line up exactly.
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

/// Column count, per-row width and artwork size for a detail page's own
/// list of child items — `SeasonEpisodeList`'s episodes,
/// `CollectionItemList`'s movies, and `PlaylistItemList`'s members.
///
/// ## Why those lists aren't one column everywhere
///
/// A single full-width row wastes most of the width it's given on iPad.
/// Measured on an 11-inch iPad: an episode row's text block ran 601pt in
/// portrait and 961pt in landscape while staying 71pt tall, and a
/// collection row's ran 686pt and 1046pt against a 90pt poster. In both
/// the trailing chevron ended up ~1,000pt from the artwork it belongs to,
/// so the row read as a small picture with a very long strip of text
/// beside it rather than as one object.
///
/// Two columns fix the measure without shrinking the list's own footprint
/// — unlike the metadata column above it (`ReadableDetailColumn`), which
/// is capped instead. The distinction is what the extra width is *for*: a
/// paragraph gains nothing from it, a list of items gains another item.
/// It also halves the scroll depth of a 20-plus-episode season.
///
/// ## Why the artwork scales
///
/// An episode row's fixed 160pt thumbnail is 187pt of a row once the
/// accent bar and spacing are counted, which a full-width row absorbs
/// easily and a 386pt half-width row does not — it would leave 199pt of
/// text, about 38 characters at `.caption`, tighter than the
/// single-column layout this is meant to improve on. Sizing the artwork
/// from the row it sits in (the same approach `PosterGridMetrics` takes
/// for poster grids) keeps the text at a workable measure at every width,
/// and on the way up gives a wide row's artwork enough height to be worth
/// the space it occupies:
///
/// | container | columns | row | 16:9 thumb | poster |
/// | --- | --- | --- | --- | --- |
/// | iPhone portrait, 402pt | 1 | 370pt | 160x90 | 90x135 |
/// | iPhone Pro Max landscape, 932pt | 2 | 442pt | 133x75 | 97x146 |
/// | iPad portrait, 820pt | 2 | 386pt | 120x68 | 90x135 |
/// | iPad landscape, 1180pt | 2 | 566pt | 170x96 | 125x188 |
///
/// `rowWidth` is what each column *will* be given, solved rather than
/// read back from the grid — see `columns` for why the grid can't be
/// asked, and what goes wrong if it is.
///
/// The single-column case deliberately keeps each list's established
/// artwork size rather than deriving it like the rest — which is to say
/// compact width renders exactly as it did before this type existed. The
/// fraction would give an iPhone portrait episode row a 111pt thumbnail
/// and shrink a layout that has no width problem to solve.
struct DetailRowGridMetrics {
    /// How one list's artwork is sized: what it stays at in a
    /// single-column layout, its shape, and how it scales once there's
    /// more than one column.
    ///
    /// A per-list value rather than per-list constants on this type
    /// because the two lists differ in every one of these numbers — a
    /// 16:9 still frame and a 2:3 poster don't want the same fraction of
    /// their row, and a poster that already starts small has nothing to
    /// give back on a narrow two-column row the way a 160pt thumbnail
    /// does.
    struct Artwork {
        /// Kept as-is whenever `columnCount` is 1.
        let singleColumnWidth: CGFloat
        /// Height as a multiple of width — 9/16 for a still frame, 1.5
        /// for a portrait poster.
        let heightRatio: CGFloat
        /// Share of the row the artwork takes once there's more than one
        /// column, before the clamps below.
        let widthFraction: CGFloat
        /// Clamps either side of `widthFraction`: the floor keeps a
        /// narrow two-column row's artwork recognisable, the ceiling
        /// stops a 13-inch iPad in landscape from turning a thumbnail
        /// into a poster (or a poster into a hero).
        let minimumWidth: CGFloat
        let maximumWidth: CGFloat

        /// The 16:9 still shared by `SeasonEpisodeList`'s episode rows
        /// and `PlaylistItemList`'s members — the latter uses the same
        /// landscape shape for every row regardless of kind, so a Movie
        /// in a playlist sizes from this rather than from `poster`
        /// below. Both start from the same 160x90 they were fixed at
        /// before this type existed.
        static let landscapeThumbnail = Artwork(
            singleColumnWidth: 160, heightRatio: 9 / 16,
            widthFraction: 0.3, minimumWidth: 120, maximumWidth: 200
        )

        /// `CollectionItemList`'s 2:3 movie poster. A smaller fraction
        /// than the thumbnail above, and a floor equal to its own
        /// single-column width: 90pt is already the smallest a poster
        /// stays legible at, so a two-column row can only ever grow it.
        static let poster = Artwork(
            singleColumnWidth: 90, heightRatio: 1.5,
            widthFraction: 0.22, minimumWidth: 90, maximumWidth: 130
        )
    }

    /// Both the gap between columns and, via each list's own
    /// `.padding(.horizontal)`, the list's outer margin.
    static let spacing: CGFloat = 16
    static let horizontalPadding: CGFloat = 16

    /// A second column has to be worth having. Below this a row can't
    /// hold artwork plus enough text to beat the full-width layout, so a
    /// list stays single-column however wide the container claims to be —
    /// which is also what a zero `containerWidth` (the first frame,
    /// before `.onGeometryChange` reports) resolves to.
    static let minimumRowWidth: CGFloat = 320

    let columnCount: Int
    let rowWidth: CGFloat
    let artworkWidth: CGFloat
    let artworkHeight: CGFloat

    /// `.flexible`, **not** `.fixed` — despite `rowWidth` already being
    /// solved to fill the container exactly, and despite
    /// `PosterGridMetrics` using `.fixed` for the same job.
    ///
    /// The difference is where the width comes from. `PosterGridMetrics`'
    /// callers read it from a `GeometryReader` wrapped *around* their
    /// `ScrollView`, so it can't be affected by what the grid then does
    /// with it. These lists have no such vantage point — each is one
    /// child among many inside a detail page's scroll content — so they
    /// measure themselves, and `.fixed` closes that into a loop: fixed
    /// columns give the grid a hard minimum width, the grid raises its
    /// container to meet it, and the container is what gets measured.
    ///
    /// Observed live (iPad, 2026-09-04): rotating landscape -> portrait
    /// left the page stuck at 1180pt inside an 820pt window — hero and
    /// episode list still landscape-width and shifted 180pt off the
    /// leading edge, permanently, because the 2 x 566pt grid kept
    /// re-asserting the width that had produced it. `.flexible` has no
    /// meaningful minimum, so the measurement stays honest and the grid
    /// divides whatever it is actually given — which, for two columns,
    /// is `rowWidth` regardless.
    ///
    /// That leaves `rowWidth` sizing only each row's artwork, where being
    /// one frame late during a rotation is invisible.
    var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top),
            count: columnCount
        )
    }

    /// Gated on horizontal size class *as well as* measured width, matching
    /// `ReadableDetailColumn` rather than width alone: an iPhone Pro Max in
    /// landscape is regular width and comfortably fits two columns, but a
    /// compact-width container that happens to be wide (a narrow Split View
    /// pane) is one the system is already treating as a phone.
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
