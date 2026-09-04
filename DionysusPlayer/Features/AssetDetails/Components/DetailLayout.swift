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
