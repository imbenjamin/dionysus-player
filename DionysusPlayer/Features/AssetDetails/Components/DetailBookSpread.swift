import SwiftUI

/// Where a detail page's two pages go on an iPhone Duo's inner display held wide,
/// partly folded like a book or fully open and flat: the poster fills the
/// leading page up to the fold, the page's own content starts after it. `nil`
/// in every other pose and on every other device.
struct DetailBookSpreadLayout: Equatable {
    /// The poster page's width, up to where the fold starts.
    let posterWidth: CGFloat
    /// Where the content page starts, past the fold.
    let contentLeadingInset: CGFloat

    /// Only a fold running top to bottom (held wide) makes a spread. Held tall,
    /// open or in tabletop, the fold runs across the page, which scrolls
    /// through it like any scrolling content, so the page keeps its hero.
    init?(fold: ActiveFold?) {
        guard case .vertical(let leading, let trailing) = fold else { return nil }
        posterWidth = leading
        contentLeadingInset = trailing
    }

    /// What the poster page shows: the poster alone, since its own artwork
    /// names the title, or, without one, the backdrop cropped to fill with the
    /// logo over it, as the hero has (Benjamin, 2026-10-26).
    enum Artwork: Equatable {
        case poster(URL)
        case backdropWithLogo(URL?)

        init(posterURL: URL?, backdropURL: URL?) {
            if let posterURL {
                self = .poster(posterURL)
            } else {
                self = .backdropWithLogo(backdropURL)
            }
        }
    }
}

extension EnvironmentValues {
    /// Set while a detail page is laid out as a book spread, so its
    /// `HeroHeaderView` steps aside for the poster page.
    @Entry var isDetailBookSpread = false
    /// The page's top safe area during a spread, bars included, which its
    /// `HeroHeaderView` clears instead of drawing the hero. The page itself
    /// ignores the top edge for the hero's sake.
    @Entry var detailBookSpreadTopInset: CGFloat = 0
}

/// A detail page as a magazine spread on an iPhone Duo's inner display held
/// wide, partly folded like a book or fully open and flat (Benjamin,
/// 2026-10-26): the poster fills the leading page, edge to edge, and everything
/// that sits under the hero (metadata, Play, tabs, chapters, rails) scrolls on
/// the trailing page. Centred, the Play button and the tabs ran straight across
/// a book-pose fold.
///
/// The poster is the item's own (`MediaItem.posterImageURL`), cropped to fill,
/// with no logo; without one, the backdrop is, with the logo over it
/// (`DetailBookSpreadLayout.Artwork`). Held tall, in tabletop, closed and on
/// every other device this is a no-op and the page keeps its hero.
private struct DetailBookSpread: ViewModifier {
    let posterURL: URL?
    let backdropURL: URL?
    let logoURL: URL?
    let title: String
    var episodeTitle: String?
    var episodeNumberAccessibilityText: String?
    var kind: BaseItemKind?

    @State private var fold: ActiveFold?
    @State private var topInset: CGFloat = 0

    func body(content: Content) -> some View {
        let spread = DetailBookSpreadLayout(fold: fold)
        content
            .environment(\.isDetailBookSpread, spread != nil)
            .environment(\.detailBookSpreadTopInset, topInset)
            .padding(.leading, spread?.contentLeadingInset ?? 0)
            .background(alignment: .leading) {
                if let spread {
                    artworkPage
                        .frame(width: spread.posterWidth)
                        .frame(maxHeight: .infinity)
                        .ignoresSafeArea()
                }
            }
            // Read after the padding, on the page's full frame: read inside it,
            // the inset would move the fold it was computed from.
            // Inactive folds too: the spread also lays out fully open and flat.
            .onActiveFoldChange(includingInactive: true) { fold = $0 }
            // Rounded, like the fold, so a sub-point move can't feed back.
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top.rounded() } action: { topInset = $0 }
    }

    @ViewBuilder
    private var artworkPage: some View {
        switch DetailBookSpreadLayout.Artwork(posterURL: posterURL, backdropURL: backdropURL) {
        case .poster(let url):
            // Sized by the clear frame, the image as its background, for the
            // reason `BackdropLogoOverlay.visualContent` gives.
            Color.clear
                .background {
                    AdaptiveArtworkImage(url: url, placeholderSystemImage: kind?.placeholderSystemImage ?? "photo")
                }
                .clipped()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(posterAccessibilityLabel)
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier(A11yID.AssetDetail.bookSpreadPoster)
        case .backdropWithLogo(let url):
            BackdropLogoOverlay(
                backdropURL: url,
                logoURL: logoURL,
                title: title,
                kind: kind,
                episodeTitle: episodeTitle,
                episodeNumberAccessibilityText: episodeNumberAccessibilityText,
                alignment: .center
            )
        }
    }

    /// What the hero's logo would have said, since the poster replaces it.
    private var posterAccessibilityLabel: String {
        [title, episodeNumberAccessibilityText, episodeTitle].compactMap { $0 }.joined(separator: ", ")
    }
}

extension View {
    /// See `DetailBookSpread`. The arguments mirror the page's `HeroHeaderView`.
    func detailBookSpread(
        posterURL: URL?,
        backdropURL: URL?,
        logoURL: URL?,
        title: String,
        episodeTitle: String? = nil,
        episodeNumberAccessibilityText: String? = nil,
        kind: BaseItemKind? = nil
    ) -> some View {
        modifier(DetailBookSpread(
            posterURL: posterURL, backdropURL: backdropURL, logoURL: logoURL, title: title,
            episodeTitle: episodeTitle, episodeNumberAccessibilityText: episodeNumberAccessibilityText, kind: kind
        ))
    }
}
