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
///
/// Lays out over two columns on regular width, via the same
/// `DetailRowGridMetrics` the episode list uses — see that type for why,
/// and for the measurements behind it. Owns its own horizontal padding
/// rather than taking it from `CollectionDetailView` (which is how it used
/// to work), so that what `.onGeometryChange` measures below is the full
/// width the list has to divide, matching what the metrics type expects.
struct CollectionItemList: View {
    let items: [MediaItem]
    /// Plays that item directly (a row's own thumbnail/play button) —
    /// distinct from tapping the row's text, which pushes into that item's
    /// own detail page via `NavigationLink` instead of swapping this page's
    /// own content in place (there's no such concept here — see
    /// `CollectionItemRow`'s doc comment).
    var onPlayItem: (String) -> Void
    /// Same "same trio" threading `PlaylistItemList` documents on its own
    /// identical properties — `CollectionDetailView` resolves these once
    /// (`viewModel.apiClient`/`.currentUserID`, `appState.downloadManager`)
    /// and passes them straight down; `nil` (a `CollectionDetailView` with
    /// no `AppState` in scope, which shouldn't happen in practice on a
    /// screen that already requires one, but degrades gracefully) omits the
    /// per-item download button entirely rather than showing one that can't
    /// actually resolve `playbackInfo`.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// This list's own width, fed to `DetailRowGridMetrics` below. See
    /// `SeasonEpisodeList.availableWidth` for why this is measured with
    /// `.onGeometryChange` rather than read from `UIScreen`/`keyWindow`,
    /// and why starting at 0 is safe.
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

            // A `LazyVGrid` only once there's genuinely more than one
            // column to lay out — the single-column case stays on the
            // `LazyVStack` it has always used, so compact width is
            // byte-identical to before this existed. Same split, same
            // reasoning, as `SeasonEpisodeList`'s.
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

    /// Shared by both branches above so the single- and multi-column
    /// lists can never drift apart in what a row actually is.
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
    /// Supplied by `DetailRowGridMetrics` rather than fixed on this type —
    /// see that type for why a row in a two-column grid can't keep the
    /// same poster size a full-width row uses.
    let posterWidth: CGFloat
    let posterHeight: CGFloat
    /// See `CollectionItemList`'s identical trio.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?

    /// Line heights of the two text styles this row stacks, used by
    /// `overviewLineLimit` below to work out how much of `posterHeight`
    /// the synopsis actually has left.
    ///
    /// `@ScaledMetric` rather than the literals alone: the whole point of
    /// deriving the line limit is that the text fits the box it's clipped
    /// to, which stops being true the moment Dynamic Type moves and the
    /// budget is still being divided by a 16pt line. Reading these also
    /// makes the limit a tracked dependency, so it recomputes when the
    /// user changes text size rather than staying at whatever it was.
    @ScaledMetric(relativeTo: .subheadline) private var titleLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var captionLineHeight: CGFloat = 16

    /// How many lines of synopsis fit under the title and metadata line
    /// within `posterHeight`.
    ///
    /// Derived rather than the flat `lineLimit(6)` this used to carry.
    /// Six lines never fit the 135pt poster this row was fixed at, so the
    /// `.clipped()` below — which is there to stop a long synopsis making
    /// the row taller than its own poster — was slicing the last line
    /// through its x-height instead of letting `Text` truncate it, which
    /// reads as a rendering fault rather than as deliberate truncation.
    /// (Measured live on an iPad, 2026-09-04: "The Last Crusade"'s row,
    /// portrait.) Two columns would have made that the common case rather
    /// than the exception, since a 386pt row wraps the same synopsis into
    /// roughly twice as many lines.
    ///
    /// Budgets two lines for the title (its own `lineLimit`) and one for
    /// the metadata line, plus the `VStack`'s two 4pt gaps. Still capped
    /// at the original 6: a 188pt poster in iPad landscape has room for
    /// more, but a wall of `.caption` prose isn't what this row is for.
    /// `.clipped()` stays as the backstop for the accessibility text
    /// sizes, where nothing computed from a fixed height can guarantee a
    /// fit.
    private var overviewLineLimit: Int {
        let reserved = titleLineHeight * 2 + captionLineHeight + 8
        return max(1, min(6, Int((posterHeight - reserved) / captionLineHeight)))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // A `ZStack`, not the download button nested inside the Play
            // `Button`'s own label — same reasoning as `EpisodeRow`'s/
            // `PlaylistItemRow`'s identical split: a button nested in
            // another button's label risks having its taps swallowed by the
            // outer one instead of reaching it. This keeps the two as
            // independent sibling tap targets layered on the same
            // thumbnail instead.
            //
            // `.bottomTrailing`, not the default `.center` — the corner
            // scheme this thumbnail follows is favorite (top-left) / watched
            // (top-right) / download (bottom-right), matching every other
            // row's thumbnail overlay in the app.
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
                // This row had no accessibility treatment at all before this —
                // found during the placeholder-imagery audit; the app's main
                // VoiceOver sweep (PR #134) predates this file and simply
                // missed it. Matches `SeasonEpisodeList.EpisodeRow`'s identical
                // thumbnail-play `Button` exactly: just a label, no extra
                // `.accessibilityElement`/trait needed since a plain `Button`
                // already reads as one element with the `.isButton` trait.
                .accessibilityLabel(String(localized: "Play \(item.name)"))

                // Same component the detail page's own Play/Resume row
                // uses — full parity (idle/preparing/downloading/
                // downloaded states, audio-track prompt, subtitle
                // warning), not a slimmed-down copy. Every item here is a
                // Movie, so `item.episodeLabel` is always `nil` — the same
                // "bare state word" fallback `EpisodeRow`'s/
                // `PlaylistItemRow`'s identical call sites document.
                if let client, let userID, let downloadManager {
                    DownloadButton(
                        item: item, client: client, userID: userID, downloadManager: downloadManager, style: .overlay,
                        accessibilityContext: item.episodeLabel
                    )
                        .padding(4)
                }
            }

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
                                    .lineLimit(overviewLineLimit)
                            }
                        }

                        Spacer(minLength: 0)

                        // Same "this row does something when tapped" cue as
                        // `EpisodeRow`'s identical trailing chevron — see its
                        // own doc comment for why this reads as "open" rather
                        // than "select in place" here specifically. Purely
                        // decorative — the `.isButton` trait below already
                        // says "this opens something," so this glyph adds no
                        // information VoiceOver needs to read on its own.
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Caps the text column to the poster's own height,
                    // top-aligned, regardless of how many lines the title
                    // actually wraps to — a fixed `lineLimit` alone (tried
                    // first) either wasted the poster's extra height under a
                    // short, 1-line title, or, under a 2-line title, let the
                    // synopsis run past the poster and make the whole row
                    // visibly taller than its own thumbnail. See
                    // `overviewLineLimit` for why the synopsis's own limit is
                    // derived from that same height rather than fixed, and
                    // for what this `.clipped()` is and isn't responsible for.
                    .frame(height: posterHeight, alignment: .top)
                    .clipped()
                    .contentShape(Rectangle())
                    // See `PosterCard.body`'s identical block for why —
                    // this row had no accessibility treatment at all
                    // before this (found during the placeholder-imagery
                    // audit); without it, VoiceOver's default combining of
                    // this stack's several `Text`s (plus the chevron, were
                    // it not hidden above) reads far less cleanly than one
                    // curated label.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityDescription)
                    .accessibilityAddTraits(.isButton)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
