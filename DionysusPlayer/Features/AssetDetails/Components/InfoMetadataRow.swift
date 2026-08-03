import SwiftUI

/// Year (range), age rating, duration, rating, and genres — the common
/// metadata line shown on every detail page.
struct InfoMetadataRow: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let year = item.yearText { Text(year) }

                if let rating = item.ageRating {
                    Text(rating)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                }

                if let duration = item.durationText { Text(duration) }

                if let communityRating = item.communityRating {
                    Label(String(format: "%.1f", communityRating), systemImage: "star.fill")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !item.genres.isEmpty {
                Text(item.genres.joined(separator: " \u{00B7} "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
