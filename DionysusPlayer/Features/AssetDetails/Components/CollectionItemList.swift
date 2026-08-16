import SwiftUI

/// A BoxSet's own child items (its movies), oldest to newest by release
/// date — `CollectionDetailView`'s counterpart to `ShowDetailView`'s
/// `SeasonEpisodeList`, same row shape (poster/thumbnail, title, a
/// metadata line, a synopsis snippet) and the same two-independent-tap-
/// targets split as `EpisodeRow` — see `CollectionItemRow`'s doc comment.
/// Drops the season picker outright: a BoxSet has no seasons.
///
/// Unlike `SeasonEpisodeList`, this doesn't fetch its own data — `items` is
/// `AssetDetailViewModel.collectionItems`, already sorted oldest-to-newest
/// (`PremiereDate` ascending) server-side, loaded (and, after a playback
/// session, refreshed) alongside `similar`/`collections` in `load()`/
/// `refreshItem()`. There's no per-selection refetch to drive here the way
/// a season switch drives `SeasonEpisodeList`'s, so there's nothing this
/// view needs to own itself.
struct CollectionItemList: View {
    let items: [MediaItem]
    /// Plays that item directly (a row's own thumbnail/play button) —
    /// distinct from tapping the row's text, which pushes into that item's
    /// own detail page via `NavigationLink` instead of swapping this page's
    /// own content in place (there's no such concept here — see
    /// `CollectionItemRow`'s doc comment).
    var onPlayItem: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Movies")
                .font(.title3.bold())

            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(items) { item in
                    CollectionItemRow(item: item, onPlay: { onPlayItem(item.id) })
                }
            }
        }
    }
}

/// The portrait-poster counterpart to `SeasonEpisodeList.EpisodeRow` — same
/// two-independent-tap-targets shape (the thumbnail plays this item
/// directly; the title/metadata/synopsis text pushes into its own detail
/// page), just with a poster-shaped thumbnail instead of a landscape one,
/// and a real `NavigationLink` push where `EpisodeRow`'s text tap only ever
/// swaps `ShowDetailView`'s own content in place — a movie inside a
/// collection already has its own full detail page, so there's nothing to
/// swap in place the way an episode's row does.
private struct CollectionItemRow: View {
    let item: MediaItem
    var onPlay: () -> Void

    private static let posterWidth: CGFloat = 90
    private var posterHeight: CGFloat { Self.posterWidth * 1.5 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onPlay) {
                ZStack {
                    AsyncRemoteImage(url: item.primaryImageURL)
                        .frame(width: Self.posterWidth, height: posterHeight)
                        .watchStatusOverlay(for: item)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Circle()
                        .fill(.black.opacity(0.55))
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                        }
                }
            }
            .buttonStyle(.plain)

            // See `PosterCard.body`'s doc comment for why the `NavigationLink`
            // needs its own `ZStack` wrapper, not just sitting bare inside
            // this row's `HStack`, when this row renders inside a
            // `LazyVStack` (`CollectionItemList` above).
            ZStack(alignment: .topLeading) {
                NavigationLink(value: AppRoute.assetDetail(itemID: item.id, preloadedItem: item)) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .lineLimit(2)

                            if let subtitle = item.railSubtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let overview = item.overview {
                                Text(overview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(6)
                            }
                        }

                        Spacer(minLength: 0)

                        // Same "this row does something when tapped" cue as
                        // `EpisodeRow`'s identical trailing chevron — see its
                        // own doc comment for why this reads as "open" rather
                        // than "select in place" here specifically.
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Caps the text column to the poster's own height,
                    // top-aligned, regardless of how many lines the title
                    // actually wraps to — a fixed `lineLimit` alone (tried
                    // first) either wasted the poster's extra height under a
                    // short, 1-line title, or, under a 2-line title, let the
                    // synopsis run past the poster and make the whole row
                    // visibly taller than its own thumbnail. `lineLimit(6)`
                    // above is deliberately generous rather than exact —
                    // this `.frame`/`.clipped()` pair is what actually
                    // enforces the height cap; the line limit just bounds
                    // how much text this ever lays out in the first place.
                    .frame(height: posterHeight, alignment: .top)
                    .clipped()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
