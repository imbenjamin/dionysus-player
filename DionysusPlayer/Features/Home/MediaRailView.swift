import SwiftUI

/// A titled horizontal-scrolling row of posters, with an optional
/// "See All" link to the full collection.
///
/// Used on both the Home page and detail pages (`MovieDetailView`'s/
/// `ShowDetailView`'s "Included In"/"More Like This" rails),
/// so the `PosterCard`/`LandscapeMediaCard` choice below (see
/// `MediaCollectionRail.usesLandscapeTiles`) applies everywhere a rail
/// shows up, not just Home.
struct MediaRailView: View {
    let rail: MediaCollectionRail

    /// Drives `posterWidth`/`landscapeWidth` below — `.regular` covers
    /// iPad in both orientations and iPhone Pro Max/Plus/Air models in
    /// landscape (see the size-class table in Apple's own Layout
    /// guidance), all cases with meaningfully more width to spend than the
    /// `PosterCard`/`LandscapeMediaCard` defaults were sized for. Found
    /// during an iPad HIG review (2026-09-03): those defaults are iPhone
    /// numbers reused everywhere, so a rail with only a couple of items
    /// (e.g. Continue Watching) left most of a wide iPad screen as dead
    /// space instead of the cards actually taking advantage of it.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// `PosterCard`'s own default (130) is what `.compact` keeps; `.regular`
    /// scales up by roughly the same ~1.23x `LandscapeMediaCard`'s own
    /// portrait/landscape ratio uses, landing on a round number rather than
    /// chasing an exact ratio.
    private var posterWidth: CGFloat { horizontalSizeClass == .regular ? 160 : 130 }
    /// Same reasoning as `posterWidth`, scaled from `LandscapeMediaCard`'s
    /// own 220 default.
    private var landscapeWidth: CGFloat { horizontalSizeClass == .regular ? 260 : 220 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                // The whole rail uses one tile shape or the other — see
                // `MediaCollectionRail.usesLandscapeTiles` — so every card
                // here is the same height and `.top` vs. the default
                // `.center` alignment makes no visible difference; `.top`
                // is just the more conventional choice for a shelf of
                // equal-height cards.
                //
                // `LazyHStack`, not `HStack` — a plain `HStack` constructs
                // and lays out every item up front regardless of whether
                // it's actually on screen, which for a 16-item rail meant
                // every one of its `AsyncRemoteImage`s fired its network
                // load immediately too. With several rails doing this at
                // once on Home's first load, that's dozens of simultaneous
                // image requests competing for the shared session's
                // connection pool — exactly the kind of burst
                // `RemoteImageLoader`'s retry logic exists to paper over,
                // rather than addressing the cause. `LazyHStack` defers
                // both construction and image loading until an item
                // actually scrolls into view.
                //
                // `usesLandscapeTiles` hoisted out of the loop — it's an
                // O(n) scan over `rail.items`, so reading it once per item
                // inside `ForEach` (an earlier version did) made rendering
                // a rail an accidental O(n²) instead of O(n).
                let usesLandscapeTiles = rail.usesLandscapeTiles
                LazyHStack(alignment: .top, spacing: 12) {
                    // `id: \.railRowIdentity`, not `MediaItem`'s own
                    // `Identifiable` id — a row whose resume position
                    // changed then has a different *identity*, which
                    // SwiftUI must act on. See that property's doc comment.
                    ForEach(rail.items, id: \.railRowIdentity) { item in
                        if usesLandscapeTiles {
                            LandscapeMediaCard(item: item, width: landscapeWidth)
                        } else {
                            PosterCard(item: item, width: posterWidth)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// The title/"See All" row — when there's a `seeAllQuery`, the whole
    /// row is one tap target (title text included, not just the "See All"
    /// label) rather than only the small trailing link, so tapping
    /// anywhere across the header — not just the couple of words of
    /// "See All" — pushes the full collection.
    ///
    /// Wrapped in a (single-child) `ZStack`, not a bare `NavigationLink` —
    /// same bare-NavigationLink-in-a-Lazy-stack freeze fix as
    /// `PosterCard`/`LandscapeMediaCard`/`LibraryCard`/`HeroRailCard` (see
    /// `library-rail-navigationlink-freeze` memory). Rendered inside
    /// `HomeView`'s `LazyVStack` of rails, this row was live-confirmed to
    /// reproduce the freeze on a plain scroll (no navigation needed) before
    /// this wrap was added.
    @ViewBuilder
    private var header: some View {
        if let query = rail.seeAllQuery {
            ZStack {
                NavigationLink(value: AppRoute.collection(query)) {
                    headerLabel(showsSeeAll: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Home.seeAll(query))
            }
        } else {
            headerLabel(showsSeeAll: false)
        }
    }

    private func headerLabel(showsSeeAll: Bool) -> some View {
        HStack {
            Text(rail.title)
                .font(.title3.bold())
                .foregroundStyle(.primary)

            Spacer()

            if showsSeeAll {
                Text("See All")
                    .font(.subheadline)
                    .foregroundStyle(Color.dionysusPrimary)
            }
        }
        .contentShape(Rectangle())
    }
}
