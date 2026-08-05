import SwiftUI

/// A tappable poster with title, used in rails and grids. Pushes
/// `.assetDetail` onto the enclosing `NavigationStack`.
///
/// The portrait counterpart to `LandscapeMediaCard` — `MediaRailView` picks
/// one or the other for an *entire* rail via
/// `MediaCollectionRail.usesLandscapeTiles` (not per item; see that
/// property's doc comment for why). Grids (`CollectionGridView`,
/// `SearchView`) always use this one regardless of item kind: they're not
/// in scope for the landscape treatment, and their column-width math
/// assumes a uniform portrait aspect ratio throughout.
struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 130

    var body: some View {
        NavigationLink(value: AppRoute.assetDetail(itemID: item.id, preloadedItem: item)) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncRemoteImage(url: item.primaryImageURL)
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .watchStatusOverlay(for: item)

                MediaCardLabel(item: item)
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The landscape 16:9 counterpart to `PosterCard`, for rail items where
/// `MediaItem.usesLandscapeRailTile` is true (series/episodes) — see that
/// property's doc comment for why. Uses the item's "Thumb" image; falls
/// back to the portrait poster image cropped to fill the same 16:9 frame
/// when no Thumb exists (`AsyncRemoteImage` defaults to `.fill` content
/// mode, so this fallback needs no special-casing here).
struct LandscapeMediaCard: View {
    let item: MediaItem
    /// Wider than `PosterCard`'s default — a 16:9 frame at that width would
    /// read as a small, oddly cramped strip; this is picked to look
    /// reasonable as its own tile, independent of `PosterCard`'s sizing.
    var width: CGFloat = 220

    var body: some View {
        NavigationLink(value: AppRoute.assetDetail(itemID: item.id, preloadedItem: item)) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncRemoteImage(url: item.thumbImageURL ?? item.primaryImageURL)
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .watchStatusOverlay(for: item)

                MediaCardLabel(item: item)
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Title/subtitle text block shared by `PosterCard` and `LandscapeMediaCard`
/// — identical in both, just sitting under differently-shaped artwork.
private struct MediaCardLabel: View {
    let item: MediaItem

    var body: some View {
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
}

private extension View {
    /// Composites the in-progress bar / fully-watched checkmark / favorite
    /// star treatment shared by `PosterCard` and `LandscapeMediaCard`, onto
    /// `self` (expected to already be the clipped artwork image).
    /// Checkmark and star sit on opposite top corners so both can show at
    /// once (a favorited, fully-watched item is a completely ordinary
    /// combination). Decorations must not intercept taps: with the progress
    /// bar as a ZStack sibling of the (rounded-clip) image, its rectangular
    /// hit region extended past the image's rounded corners and could get
    /// routed to a neighbouring card in the horizontal `ScrollView` — hence
    /// `allowsHitTesting(false)`.
    func watchStatusOverlay(for item: MediaItem) -> some View {
        self
            .overlay(alignment: .bottom) {
                if let fraction = item.playedFraction, fraction > 0, !item.isPlayed {
                    ProgressView(value: fraction)
                        .tint(.dionysusHighlight)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                }
            }
            .overlay(alignment: .topLeading) {
                if item.isFavorite {
                    // `.circle.fill`, not plain `.fill` — matches
                    // `checkmark.circle.fill` below: both are two-layer SF
                    // Symbols (a filled circle behind the glyph), which is
                    // what makes the two-color `.foregroundStyle` below
                    // actually paint two different colors instead of the
                    // second one going unused on a single-layer glyph.
                    Image(systemName: "star.circle.fill")
                        .foregroundStyle(Color.white, Color.dionysusHighlight)
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.isPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.white, Color.dionysusPrimary)
                        .padding(4)
                }
            }
            .allowsHitTesting(false)
    }
}
