import SwiftUI

/// A titled horizontal-scrolling row of posters, with an optional
/// "See All" link to the full collection.
///
/// Used on both the Home page and detail pages (`MovieDetailView`'s/
/// `ShowDetailView`'s "Part of These Collections"/"More Like This" rails),
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
                HStack(alignment: .top, spacing: 12) {
                    ForEach(rail.items) { item in
                        if rail.usesLandscapeTiles {
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
