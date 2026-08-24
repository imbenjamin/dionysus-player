import SwiftUI

/// Year (range) — or, for an individual episode, its exact air date, e.g.
/// "1 Aug 2026" (see `MediaItem.metadataDateText`) — age rating, duration,
/// and rating on the first line; a dot-separated line of resolution/
/// dynamic-range/audio-format/accessibility badges on the second — the
/// common metadata shown on every detail page. Genres moved to the "About"
/// tab (`DetailTabsView`), above the synopsis; badges took their old spot
/// on the second line.
struct InfoMetadataRow: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let date = item.metadataDateText { Text(date) }

                if let rating = item.ageRating {
                    Text(rating)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                }

                if let duration = item.durationText { Text(duration) }

                if let communityRating = item.communityRating {
                    // `Label`'s default icon/title spacing reads as too wide
                    // here — closer to the two being separate items than one
                    // "★ 4.8" rating — so a plain HStack with an explicit,
                    // tight spacing instead.
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                        Text(String(format: "%.1f", communityRating))
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !item.metadataBadges.isEmpty {
                Text(item.metadataBadges.joined(separator: " \u{00B7} "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
