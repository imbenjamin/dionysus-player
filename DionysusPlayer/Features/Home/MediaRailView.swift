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
            HStack {
                Text(rail.title)
                    .font(.title3.bold())

                Spacer()

                if let query = rail.seeAllQuery {
                    NavigationLink(value: AppRoute.collection(query)) {
                        Text("See All")
                            .font(.subheadline)
                            .foregroundStyle(Color.dionysusPrimary)
                    }
                }
            }
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
}
