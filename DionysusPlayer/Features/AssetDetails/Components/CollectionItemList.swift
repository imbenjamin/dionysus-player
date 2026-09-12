import SwiftUI

/// A BoxSet's child movies, oldest to newest by release date —
/// `CollectionDetailView`'s counterpart to `SeasonEpisodeList`, with the same row
/// shape and two-independent-tap-targets split as `EpisodeRow` (see
/// `CollectionItemRow`). No season picker: a BoxSet has no seasons.
///
/// Unlike `SeasonEpisodeList` this doesn't fetch its own data: `items` is
/// `AssetDetailViewModel.collectionItems`, sorted `PremiereDate` ascending
/// server-side and loaded alongside `similar`/`collections` in
/// `load()`/`refreshItem()`. There's no per-selection refetch to drive the way a
/// season switch drives `SeasonEpisodeList`'s.
///
/// Lays out over two columns on regular width via `DetailRowGridMetrics`. Owns
/// its horizontal padding rather than inheriting it from
/// `CollectionDetailView`, so `.onGeometryChange` below measures the full width
/// the list divides.
struct CollectionItemList: View {
    let items: [MediaItem]
    /// Plays that item directly, from a row's thumbnail play button. Distinct
    /// from tapping the row's text, which pushes its detail page via
    /// `NavigationLink` — there's no swap-in-place here, see
    /// `CollectionItemRow`.
    var onPlayItem: (String) -> Void
    /// The same trio `PlaylistItemList` documents: `CollectionDetailView`
    /// resolves these once and passes them down. `nil` omits the per-item
    /// download button rather than showing one that can't resolve
    /// `playbackInfo`.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// This list's width, fed to `DetailRowGridMetrics`. See
    /// `SeasonEpisodeList.availableWidth` for why it's measured with
    /// `.onGeometryChange` rather than read off the window, and why 0 is a safe
    /// start.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Movies")
                .font(.title3.bold())
                .padding(.horizontal)

            let metrics = DetailRowGridMetrics(
                containerWidth: availableWidth, isRegularWidth: horizontalSizeClass == .regular,
                artwork: .poster
            )

            // A `LazyVGrid` only when there's more than one column; the
            // single-column case stays on a `LazyVStack`. Same split as
            // `SeasonEpisodeList`.
            if metrics.columnCount > 1 {
                LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: 16) {
                    itemRows(metrics: metrics)
                }
                .padding(.horizontal)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    itemRows(metrics: metrics)
                }
                .padding(.horizontal)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    /// Shared by both branches above so the single- and multi-column lists
    /// can't drift apart.
    @ViewBuilder
    private func itemRows(metrics: DetailRowGridMetrics) -> some View {
        ForEach(items) { item in
            CollectionItemRow(
                item: item, onPlay: { onPlayItem(item.id) },
                posterWidth: metrics.artworkWidth, posterHeight: metrics.artworkHeight,
                client: client, userID: userID, downloadManager: downloadManager
            )
        }
    }
}

/// The portrait-poster counterpart to `SeasonEpisodeList.EpisodeRow`: same two
/// independent tap targets, with a poster-shaped thumbnail and a real
/// `NavigationLink` push where `EpisodeRow`'s text tap swaps
/// `ShowDetailView`'s content in place. A movie in a collection has its own
/// detail page, so there's nothing to swap.
private struct CollectionItemRow: View {
    let item: MediaItem
    var onPlay: () -> Void
    /// Supplied by `DetailRowGridMetrics` rather than fixed here — see that type
    /// for why a two-column row can't keep a full-width row's poster size.
    let posterWidth: CGFloat
    let posterHeight: CGFloat
    /// See `CollectionItemList`'s identical trio.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?

    /// Line heights of the two text styles this row stacks, used by
    /// `overviewLineLimit` to work out how much of `posterHeight` the synopsis
    /// has left.
    ///
    /// `@ScaledMetric` rather than the literals: a derived line limit only fits
    /// its box while the budget is divided by the real line height, not a fixed
    /// 16pt one. Reading these also makes the limit a tracked dependency, so it
    /// recomputes when the user changes text size.
    @ScaledMetric(relativeTo: .subheadline) private var titleLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var captionLineHeight: CGFloat = 16

    /// How many lines of synopsis fit under the title and metadata line
    /// within `posterHeight`.
    ///
    /// Derived rather than a flat `lineLimit(6)`. Six lines never fit the 135pt
    /// poster this row was fixed at, so `.clipped()` — there to stop a long
    /// synopsis making the row taller than its poster — sliced the last line
    /// through its x-height instead of letting `Text` truncate, reading as a
    /// rendering fault. Two columns would have made that the common case, since a
    /// 386pt row wraps the same synopsis into roughly twice as many lines.
    ///
    /// Budgets two lines for the title and one for the metadata line, plus the
    /// `VStack`'s two 4pt gaps. Still capped at 6: a 188pt poster in iPad
    /// landscape has room for more, but a wall of `.caption` prose isn't what
    /// this row is for. `.clipped()` remains the backstop at accessibility text
    /// sizes, where nothing computed from a fixed height can guarantee a fit.
    private var overviewLineLimit: Int {
        let reserved = titleLineHeight * 2 + captionLineHeight + 8
        return max(1, min(6, Int((posterHeight - reserved) / captionLineHeight)))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // A `ZStack`, not the download button inside the Play `Button`'s
            // label: a nested button risks its taps being swallowed by the outer
            // one. Same split as `EpisodeRow`/`PlaylistItemRow`.
            //
            // `.bottomTrailing`, not the default `.center`, following this
            // thumbnail's corner scheme: favorite (top-left) / watched
            // (top-right) / download (bottom-right).
            ZStack(alignment: .bottomTrailing) {
                Button(action: onPlay) {
                    ZStack {
                        AsyncRemoteImage(url: item.primaryImageURL, placeholderSystemImage: item.kind.placeholderSystemImage)
                            .frame(width: posterWidth, height: posterHeight)
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
                // Matches `SeasonEpisodeList.EpisodeRow`'s thumbnail-play
                // `Button`: just a label, since a plain `Button` already reads as
                // one element with the `.isButton` trait.
                .accessibilityLabel(String(localized: "Play \(item.name)"))

                // The same component the detail page's Play/Resume row uses, at
                // full parity. Every item here is a Movie, so
                // `item.episodeLabel` is always `nil`, falling back to the bare
                // state word.
                if let client, let userID, let downloadManager {
                    DownloadButton(
                        item: item, client: client, userID: userID, downloadManager: downloadManager, style: .overlay,
                        accessibilityContext: item.episodeLabel
                    )
                        .padding(4)
                }
            }

            // See `PosterCard.body` for why the `NavigationLink` needs its own
            // `ZStack` wrapper inside a `LazyVStack` rather than sitting bare in
            // this `HStack`.
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
                                    .lineLimit(overviewLineLimit)
                            }
                        }

                        Spacer(minLength: 0)

                        // The same "this row does something when tapped" cue as
                        // `EpisodeRow`'s trailing chevron. Decorative: the
                        // `.isButton` trait below already conveys it.
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Caps the text column to the poster's height, top-aligned,
                    // whatever the title wraps to. A fixed `lineLimit` alone
                    // either wasted the poster's height under a one-line title
                    // or, under a two-line one, let the synopsis run past the
                    // poster and make the row taller than its thumbnail. See
                    // `overviewLineLimit` for what this `.clipped()` is and isn't
                    // responsible for.
                    .frame(height: posterHeight, alignment: .top)
                    .clipped()
                    .contentShape(Rectangle())
                    // See `PosterCard.body`'s identical block: VoiceOver's
                    // default combining of this stack's several `Text`s reads
                    // less cleanly than one curated label.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityDescription)
                    .accessibilityAddTraits(.isButton)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
