import SwiftUI

/// A Playlist's own member items, in the playlist's own stored order —
/// `PlaylistDetailView`'s counterpart to `CollectionDetailView`'s
/// `CollectionItemList`, same two-independent-tap-targets row shape and the
/// same `NavigationLink`-push-per-row navigation (a Playlist's members
/// already have their own full detail pages, same as a BoxSet's — see
/// `PlaylistItemRow`'s doc comment). Unlike a BoxSet's members, though, a
/// Playlist can mix Movies and Episodes together — every row uses the same
/// landscape thumbnail shape regardless of kind (a deliberate uniformity
/// choice, unlike `PosterCard`/`LandscapeMediaCard`'s kind-dependent split
/// elsewhere in the app — see `PlaylistItemRow`'s doc comment), with
/// `railTitle`/`railSubtitle` handling the metadata difference instead, so
/// nothing here needs to special-case which kind a given row actually is.
///
/// Doesn't fetch its own data — `items` is
/// `AssetDetailViewModel.orderedPlaylistItems`, already fetched (and
/// audio/music-filtered) alongside `similar`/`collections` in `load()`/
/// `refreshItem()`.
struct PlaylistItemList: View {
    let items: [MediaItem]
    /// Plays that item, joining the same Up Next chain as every other row
    /// and the page's own Play/Resume button — see `PlaylistDetailView`'s
    /// doc comment for why a single shared queue covers all three. Distinct
    /// from tapping the row's text, which pushes into that item's own
    /// detail page instead.
    var onPlayItem: (String) -> Void
    /// `nil` (no live session) omits every row's `DownloadButton` overlay
    /// entirely — same graceful-degradation shape `SeasonEpisodeList.EpisodeRow`
    /// already uses for the same reason.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Items")
                .font(.title3.bold())

            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(items) { item in
                    PlaylistItemRow(
                        item: item, onPlay: { onPlayItem(item.id) },
                        client: client, userID: userID, downloadManager: downloadManager
                    )
                }
            }
        }
    }
}

/// One playlist member — mirrors `CollectionItemList.CollectionItemRow`'s
/// two-independent-tap-targets shape (thumbnail plays this item directly;
/// title/metadata/synopsis text pushes into its own detail page via
/// `NavigationLink`, since a movie or episode inside a playlist already has
/// its own full detail page, same reasoning as a BoxSet's member row) —
/// just always landscape-shaped (the "Thumb" image, `item.thumbImageURL`,
/// falling back to the poster image cropped to fill the same 16:9 frame
/// when no Thumb exists — same fallback `LandscapeMediaCard` uses) rather
/// than switching to a poster for a Movie member the way a rail tile does
/// elsewhere in the app (`MediaItem.usesLandscapeRailTile`). Confirmed with
/// the user (2026-09-02): a uniform shape reads better in this specific
/// list than the kind-dependent split. `railTitle`/`railSubtitle` still
/// handle the metadata difference with no further branching needed here: a
/// Movie member shows its own name + "year · duration"; an Episode member
/// shows its series name + "S1:E4 · Episode Name" — exactly what
/// distinguishes rows from different shows/movies in a mixed playlist.
private struct PlaylistItemRow: View {
    let item: MediaItem
    var onPlay: () -> Void
    /// `nil` (no live session — shouldn't happen in practice on a screen
    /// that already requires one, but degrades gracefully) omits the
    /// per-item download button entirely rather than showing one that
    /// can't actually resolve `playbackInfo` — same as `EpisodeRow`'s
    /// identical trio.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?

    private static let thumbnailWidth: CGFloat = 160
    private static let thumbnailHeight: CGFloat = 90

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // A `ZStack`, not the download button nested inside the Play
            // `Button`'s own label — same reasoning as `EpisodeRow`'s
            // identical split: a button nested in another button's label
            // risks having its taps swallowed by the outer one instead of
            // reaching it. This keeps the two as independent sibling tap
            // targets layered on the same thumbnail instead.
            ZStack(alignment: .topTrailing) {
                Button(action: onPlay) {
                    ZStack {
                        AsyncRemoteImage(
                            url: item.thumbImageURL ?? item.primaryImageURL,
                            placeholderSystemImage: item.kind.placeholderSystemImage
                        )
                        .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
                        // Same show-logo treatment Home's own episode rail
                        // tiles use (`LandscapeMediaCard`) — self-gated to
                        // `.episode` items with a logo, so a Movie member's
                        // thumbnail is untouched. Applied before the Play
                        // button's circle+glyph below (a `ZStack` sibling, not
                        // part of this `.overlay` chain), so the logo sits
                        // bottom-left underneath it rather than competing for
                        // the same center spot.
                        .episodeLogoOverlay(for: item)
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
                // Same treatment as `CollectionItemRow`'s identical thumbnail
                // `Button` — a plain `Button` already reads as one VoiceOver
                // element with the `.isButton` trait, so just a label is needed.
                .accessibilityLabel(String(localized: "Play \(item.railTitle)"))

                // Same component the detail page's own Play/Resume row
                // uses — full parity (idle/preparing/downloading/
                // downloaded states, audio-track prompt, subtitle
                // warning), not a slimmed-down copy. `item.episodeLabel`
                // is `nil` for a Movie member, same "bare state word"
                // fallback `EpisodeRow`'s identical call site documents.
                if let client, let userID, let downloadManager {
                    DownloadButton(
                        item: item, client: client, userID: userID, downloadManager: downloadManager, style: .overlay,
                        accessibilityContext: item.episodeLabel
                    )
                        .padding(4)
                }
            }

            // See `PosterCard.body`'s doc comment for why the
            // `NavigationLink` needs its own `ZStack` wrapper, not just
            // sitting bare inside this row's `HStack`, when this row
            // renders inside a `LazyVStack` (`PlaylistItemList` above).
            ZStack(alignment: .topLeading) {
                NavigationLink(value: AppRoute.assetDetail(itemID: item.id, preloadedItem: item)) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.railTitle)
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

                        // Purely decorative "this opens something" cue —
                        // same reasoning as `CollectionItemRow`'s identical
                        // chevron.
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Caps the text column to the thumbnail's own height,
                    // top-aligned — see `CollectionItemRow`'s identical
                    // `.frame`/`.clipped()` pair for why this (not a fixed
                    // `lineLimit` alone) is what actually enforces it.
                    .frame(height: Self.thumbnailHeight, alignment: .top)
                    .clipped()
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityDescription)
                    .accessibilityAddTraits(.isButton)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
