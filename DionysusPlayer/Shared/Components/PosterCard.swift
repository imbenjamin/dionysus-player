import SwiftUI

/// A tappable poster with title, used in rails and grids. Pushes
/// `.assetDetail` onto the enclosing `NavigationStack`.
struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 130

    var body: some View {
        NavigationLink(value: AppRoute.assetDetail(itemID: item.id, preloadedItem: item)) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncRemoteImage(url: item.primaryImageURL)
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottom) {
                        if let fraction = item.playedFraction, fraction > 0, !item.isPlayed {
                            ProgressView(value: fraction)
                                .tint(.dionysusHighlight)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 4)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if item.isPlayed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.white, Color.dionysusPrimary)
                                .padding(4)
                        }
                    }
                    // Decorations must not intercept taps: with the progress bar
                    // as a ZStack sibling of the (rounded-clip) image, its
                    // rectangular hit region extended past the image's rounded
                    // corners and could get routed to a neighbouring card in the
                    // horizontal ScrollView.
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.railTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if let subtitle = item.railSubtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
