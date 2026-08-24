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
                    ForEach(rail.items) { item in
                        if usesLandscapeTiles {
                            LandscapeMediaCard(item: item)
                        } else {
                            PosterCard(item: item)
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
