import SwiftUI

/// A tappable poster with title, used in rails and grids. Pushes
/// `.assetDetail` onto the enclosing `NavigationStack`.
struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 130

    var body: some View {
        NavigationLink(value: AppRoute.assetDetail(itemID: item.id)) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    AsyncRemoteImage(url: item.primaryImageURL)
                        .frame(width: width, height: width * 1.5)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if let fraction = item.playedFraction, fraction > 0, !item.isPlayed {
                        ProgressView(value: fraction)
                            .tint(.red)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                    }

                    if item.isPlayed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, .tint)
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }

                Text(item.episodeLabel.map { "\($0) · \(item.name)" } ?? item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
    }
}
