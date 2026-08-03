import SwiftUI

/// A titled horizontal-scrolling row of posters, with an optional
/// "See All" link to the full collection.
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
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(rail.items) { item in
                        PosterCard(item: item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
