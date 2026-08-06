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
/// assumes a uniform portrait aspect ratio throughout — episode items can
/// still show up here (e.g. search results), which is why the "More" menu
/// below isn't exclusive to `LandscapeMediaCard`.
struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 130

    private var imageHeight: CGFloat { width * 1.5 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NavigationLink(value: AppRoute.assetDetail(itemID: item.id, preloadedItem: item)) {
                VStack(alignment: .leading, spacing: 6) {
                    AsyncRemoteImage(url: item.primaryImageURL)
                        .frame(width: width, height: imageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .watchStatusOverlay(for: item)

                    MediaCardLabel(item: item)
                }
                .frame(width: width)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            EpisodeMoreMenuButton(item: item)
                .frame(width: width, height: imageHeight, alignment: .bottomTrailing)
        }
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

    private var imageHeight: CGFloat { width * 9 / 16 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NavigationLink(value: AppRoute.assetDetail(itemID: item.id, preloadedItem: item)) {
                VStack(alignment: .leading, spacing: 6) {
                    AsyncRemoteImage(url: item.thumbImageURL ?? item.primaryImageURL)
                        .frame(width: width, height: imageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .watchStatusOverlay(for: item)

                    MediaCardLabel(item: item)
                }
                .frame(width: width)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            EpisodeMoreMenuButton(item: item)
                .frame(width: width, height: imageHeight, alignment: .bottomTrailing)
        }
    }
}

/// The "⋯" corner menu button shown only on episode tiles, in both
/// `PosterCard` and `LandscapeMediaCard` — nothing renders for any other
/// item kind. Just one action for now (jump to the episode's parent Show);
/// more can be added to the `Menu`'s content later without callers changing.
///
/// A sibling of the card's `NavigationLink` in an outer `ZStack`, not
/// nested inside its label — an interactive control nested inside a
/// `NavigationLink`'s label risks having its taps swallowed by the link's
/// own tap gesture instead of reaching the control. Being an independent
/// sibling avoids that; callers give it a `.frame(width:height:alignment:
/// .bottomTrailing)` matching the artwork image's own size (not the whole
/// card, which also has the text label below) so it lands in the image's
/// bottom-right corner specifically, same as `watchStatusOverlay`'s badges
/// sit relative to the image rather than the whole card.
private struct EpisodeMoreMenuButton: View {
    let item: MediaItem

    var body: some View {
        if item.kind == .episode, let seriesID = item.seriesID {
            Menu {
                NavigationLink(value: AppRoute.assetDetail(itemID: seriesID)) {
                    Label("Go to Show", systemImage: "tv")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .padding(6)
        }
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
    /// combination) — the bottom-trailing corner is reserved for
    /// `EpisodeMoreMenuButton`, which is why nothing here uses that
    /// alignment. Decorations must not intercept taps: with the progress
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
